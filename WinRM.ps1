#requires -Version 5.1
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$global:Cred = $null
$global:Jobs = @()
$global:JobTimer = $null

function Get-AppCredential {
    $global:Cred = Get-Credential -Message "Insérez la carte à puce et entrez le PIN"
}

function Append-Log {
    param([System.Windows.Controls.TextBox]$Box, [string]$Text)
    if (-not $Box) { return }
    $Box.Dispatcher.Invoke([action]{
        $Box.AppendText($Text)
        $Box.ScrollToEnd()
    }, "Normal")
}

function Update-StatusBar {
    param([string]$Text, [string]$Type = "Info")
    if (-not $script:lblStatus) { return }
    $script:lblStatus.Dispatcher.Invoke([action]{
        $script:lblStatus.Content = $Text
        $script:lblStatus.Foreground = switch ($Type) {
            "Success" { [System.Windows.Media.Brushes]::LightGreen }
            "Error"   { [System.Windows.Media.Brushes]::Tomato }
            "Warning" { [System.Windows.Media.Brushes]::Orange }
            default   { [System.Windows.Media.Brushes]::White }
        }
    }, "Normal")
}

function Update-ServerCount {
    if (-not $script:lblServerCount -or -not $script:lstServers) { return }
    $total = $script:lstServers.Items.Count
    $selected = $script:lstServers.SelectedItems.Count
    if ($selected -gt 0) {
        $script:lblServerCount.Content = "$selected / $total serveur(s)"
    } else {
        $script:lblServerCount.Content = "$total serveur(s)"
    }
}

function Start-CommandJobs {
    param(
        [string[]]$Servers,
        [string]$Command,
        [System.Windows.Controls.TextBox]$OutputBox,
        [System.Windows.Controls.Button]$RunButton,
        [System.Windows.Controls.Button]$CancelButton
    )

    if (-not $global:Cred) { Get-AppCredential }
    if (-not $global:Cred) { Append-Log $OutputBox "Aucun identifiant. Abandonné.`r`n"; return }

    $RunButton.IsEnabled = $false
    $CancelButton.IsEnabled = $true
    $global:Jobs = @()

    $script:progressBar.Visibility = "Visible"
    $script:progressBar.IsIndeterminate = $true
    Update-StatusBar "Exécution en cours sur $($Servers.Count) serveur(s)..." "Warning"

    foreach ($s in $Servers) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $job = Start-Job -Name "Cmd:$s" -ArgumentList $s,$Command,$global:Cred -ScriptBlock {
            param($Server,$Cmd,$Cred)
            $result = New-Object System.Collections.Generic.List[psobject]
            try {
                $out = Invoke-Command -ComputerName $Server -Credential $Cred -ScriptBlock {
                    param($CmdInner)
                    Invoke-Expression $CmdInner
                } -ArgumentList $Cmd -ErrorAction Stop
                $result.Add([pscustomobject]@{ Server=$Server; Kind="Output"; Data=($out | Out-String) })
            } catch {
                $result.Add([pscustomobject]@{ Server=$Server; Kind="Error"; Data=$_.Exception.Message })
            }
            $result
        }
        $global:Jobs += $job
    }

    if (-not $global:JobTimer) {
        $global:JobTimer = New-Object System.Windows.Threading.DispatcherTimer
        $global:JobTimer.Interval = [TimeSpan]::FromMilliseconds(800)
        $global:JobTimer.Add_Tick({
            $done = @()
            foreach ($j in $global:Jobs) {
                if ($j.HasMoreData) {
                    $data = Receive-Job -Job $j -Keep
                    foreach ($line in $data) {
                        $prefix = if ($line.Kind -eq "Error") { "[ERREUR] " } else { "" }
                        Append-Log $script:txtOut ("{0}{1}:`r`n{2}`r`n" -f $prefix,$line.Server,$line.Data)
                    }
                }
                if ($j.State -in "Completed","Failed","Stopped") { $done += $j }
            }
            if ($global:Jobs.Count -gt 0) {
                Update-StatusBar "Progression : $($done.Count) / $($global:Jobs.Count) terminé(s)" "Warning"
            }
            if ($global:Jobs.Count -gt 0 -and $done.Count -eq $global:Jobs.Count) {
                foreach ($dj in $global:Jobs) { Remove-Job -Job $dj -Force -ErrorAction SilentlyContinue }
                $global:Jobs = @()
                $script:btnRun.IsEnabled = $true
                $script:btnCancel.IsEnabled = $false
                $script:progressBar.Visibility = "Collapsed"
                $script:progressBar.IsIndeterminate = $false
                Append-Log $script:txtOut "Toutes les tâches sont terminées.`r`n"
                Update-StatusBar "Toutes les tâches sont terminées." "Success"
                $global:JobTimer.Stop()
            }
        })
    }
    $global:JobTimer.Start()
}

function Stop-CommandJobs {
    foreach ($j in $global:Jobs) {
        try { Stop-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
    }
    $global:Jobs = @()
    if ($global:JobTimer) { $global:JobTimer.Stop() }
    if ($script:progressBar) {
        $script:progressBar.Visibility = "Collapsed"
        $script:progressBar.IsIndeterminate = $false
    }
}

function Test-Servers {
    param([string[]]$Servers, [System.Windows.Controls.TextBox]$OutputBox)
    $ok_count = 0; $ko_count = 0
    foreach ($s in $Servers) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $ok = $false
        try { Test-WSMan -ComputerName $s -ErrorAction Stop | Out-Null; $ok = $true } catch { $ok = $false }
        $msg = if ($ok) { $ok_count++; "[OK] " } else { $ko_count++; "[KO] " }
        Append-Log $OutputBox ($msg + $s + "`r`n")
    }
    Update-StatusBar "Test terminé : $ok_count OK, $ko_count KO" $(if ($ko_count -eq 0) { "Success" } else { "Warning" })
}

function Get-ForestDomains {
    try { [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().Domains.Name } catch { @() }
}

function Find-ServersInForest {
    param([string]$Pattern, [int]$PerDomainLimit=500, [switch]$ServersOnly)
    $list = New-Object System.Collections.Generic.List[string]
    $domains = Get-ForestDomains
    if (-not $domains -or $domains.Count -eq 0) { return @() }
    $adModule = $false
    try { Import-Module ActiveDirectory -ErrorAction Stop; $adModule = $true } catch {}

    foreach ($dom in $domains) {
        if ($adModule) {
            try {
                $flt = if ($ServersOnly) { "OperatingSystem -like '*Server*' -and Name -like '$Pattern'" } else { "Name -like '$Pattern'" }
                $objs = Get-ADComputer -Filter $flt -Server $dom -Properties DNSHostName -ResultSetSize $PerDomainLimit -ErrorAction Stop
                foreach ($o in $objs) {
                    if ($o.DNSHostName) { $null = $list.Add($o.DNSHostName) }
                    elseif ($o.Name) { $null = $list.Add(($o.Name + "." + $dom)) }
                }
            } catch {}
        } else {
            try {
                $root = "LDAP://$dom"
                $de = New-Object System.DirectoryServices.DirectoryEntry($root)
                $ds = New-Object System.DirectoryServices.DirectorySearcher($de)
                $ds.PageSize = 1000
                $ds.SizeLimit = $PerDomainLimit
                $ds.Filter = if ($ServersOnly) {
                    "(&(objectClass=computer)(name=$Pattern)(|(operatingSystem=*Server*)(operatingSystem=*server*)))"
                } else {
                    "(&(objectClass=computer)(name=$Pattern))"
                }
                $ds.PropertiesToLoad.Clear()
                [void]$ds.PropertiesToLoad.Add("dnshostname")
                [void]$ds.PropertiesToLoad.Add("name")
                $res = $ds.FindAll()
                foreach ($r in $res) {
                    if ($r.Properties["dnshostname"] -and $r.Properties["dnshostname"][0]) {
                        $null = $list.Add([string]$r.Properties["dnshostname"][0])
                    } elseif ($r.Properties["name"] -and $r.Properties["name"][0]) {
                        $null = $list.Add(([string]$r.Properties["name"][0] + "." + $dom))
                    }
                }
            } catch {}
        }
    }
    $list | Where-Object { $_ } | Sort-Object -Unique
}

function Export-Selection {
    param([System.Windows.Controls.ListBox]$List)
    $targets = @($List.SelectedItems)
    if (-not $targets -or $targets.Count -eq 0) { return $false }

    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
    $dlg.FileName = "servers.txt"
    if ($dlg.ShowDialog() -ne $true) { return $false }
    try { $targets | Set-Content -Path $dlg.FileName -Encoding UTF8; return $true } catch { return $false }
}

function Import-Merge {
    param([System.Windows.Controls.ListBox]$List)
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = "Text files (*.txt)|*.txt|CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    if ($dlg.ShowDialog() -ne $true) { return 0 }

    $lines = @()
    try { $lines = Get-Content -Path $dlg.FileName -ErrorAction Stop } catch { return 0 }
    $added = 0
    foreach ($l in $lines) {
        $sv = ([string]$l).Trim()
        if ($sv -and -not $List.Items.Contains($sv)) { $null = $List.Items.Add($sv); $added++ }
    }
    return $added
}

# =====================================================================
# XAML Interface Definition - v3.0
# =====================================================================
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinRM - Outil de Commande a Distance"
        Height="820" Width="1280"
        MinHeight="600" MinWidth="900"
        WindowStartupLocation="CenterScreen"
        Background="#FF1B1B1F">

    <Window.Resources>

        <!-- Couleurs globales -->
        <SolidColorBrush x:Key="AccentBrush" Color="#FF0078D4"/>
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#FF1A8FE8"/>
        <SolidColorBrush x:Key="AccentPressedBrush" Color="#FF005FA3"/>
        <SolidColorBrush x:Key="SurfaceBrush" Color="#FF252529"/>
        <SolidColorBrush x:Key="SurfaceAltBrush" Color="#FF2D2D32"/>
        <SolidColorBrush x:Key="BackgroundBrush" Color="#FF1B1B1F"/>
        <SolidColorBrush x:Key="BorderBrush" Color="#FF3A3A42"/>
        <SolidColorBrush x:Key="BorderHoverBrush" Color="#FF505060"/>
        <SolidColorBrush x:Key="TextPrimaryBrush" Color="#FFFFFFFF"/>
        <SolidColorBrush x:Key="TextSecondaryBrush" Color="#FFB0B0BC"/>
        <SolidColorBrush x:Key="TextMutedBrush" Color="#FF6E6E7E"/>
        <SolidColorBrush x:Key="DangerBrush" Color="#FFE81123"/>
        <SolidColorBrush x:Key="DangerHoverBrush" Color="#FFFF2B40"/>
        <SolidColorBrush x:Key="SuccessBrush" Color="#FF16C60C"/>
        <SolidColorBrush x:Key="WarningBrush" Color="#FFFFC107"/>
        <SolidColorBrush x:Key="TerminalBgBrush" Color="#FF0A0A0E"/>

        <!-- Style Bouton principal -->
        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Margin" Value="2"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}"
                                BorderThickness="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{StaticResource AccentHoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{StaticResource AccentPressedBrush}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF3A3A42"/>
                                <Setter Property="Foreground" Value="#FF6E6E7E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Style Bouton secondaire (gris) -->
        <Style x:Key="SecondaryButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource SurfaceAltBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Margin" Value="2"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                BorderBrush="{TemplateBinding BorderBrush}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF3E3E46"/>
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource BorderHoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#FF45454F"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF2A2A2E"/>
                                <Setter Property="Foreground" Value="#FF6E6E7E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Style Bouton danger -->
        <Style x:Key="DangerButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource DangerBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Margin" Value="2"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}"
                                BorderThickness="0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{StaticResource DangerHoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#FF3A3A42"/>
                                <Setter Property="Foreground" Value="#FF6E6E7E"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Style par defaut des boutons = Primary -->
        <Style TargetType="Button" BasedOn="{StaticResource PrimaryButton}"/>

        <!-- Style TextBox -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource SurfaceAltBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="CaretBrush" Value="White"/>
            <Setter Property="SelectionBrush" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Name="border"
                                Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="0"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="BorderBrush" Value="{StaticResource BorderHoverBrush}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Style ListBox -->
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="{StaticResource SurfaceBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="2"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4">
                            <ScrollViewer Focusable="False" Padding="{TemplateBinding Padding}">
                                <ItemsPresenter/>
                            </ScrollViewer>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="Margin" Value="1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border Name="border"
                                Background="{TemplateBinding Background}"
                                CornerRadius="3"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{StaticResource AccentBrush}"/>
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition Property="IsSelected" Value="False"/>
                                    <Condition Property="IsMouseOver" Value="True"/>
                                </MultiTrigger.Conditions>
                                <Setter TargetName="border" Property="Background" Value="#FF35353D"/>
                            </MultiTrigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Style ComboBox -->
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="Background" Value="{StaticResource SurfaceAltBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton Name="ToggleButton"
                                          Background="{TemplateBinding Background}"
                                          BorderBrush="{TemplateBinding BorderBrush}"
                                          BorderThickness="{TemplateBinding BorderThickness}"
                                          Focusable="False"
                                          IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border Name="tbBorder"
                                                Background="{TemplateBinding Background}"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                BorderThickness="{TemplateBinding BorderThickness}"
                                                CornerRadius="4">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition/>
                                                    <ColumnDefinition Width="28"/>
                                                </Grid.ColumnDefinitions>
                                                <ContentPresenter Grid.Column="0"/>
                                                <Path Grid.Column="1" Name="Arrow"
                                                      Fill="{StaticResource TextSecondaryBrush}"
                                                      HorizontalAlignment="Center"
                                                      VerticalAlignment="Center"
                                                      Data="M 0 0 L 5 5 L 10 0 Z"/>
                                            </Grid>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True">
                                                <Setter TargetName="tbBorder" Property="BorderBrush" Value="{StaticResource BorderHoverBrush}"/>
                                            </Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter Name="ContentSite"
                                            Content="{TemplateBinding SelectionBoxItem}"
                                            ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                            ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                            VerticalAlignment="Center"
                                            HorizontalAlignment="Left"
                                            Margin="10,0,28,0"
                                            IsHitTestVisible="False"/>
                            <Popup Name="Popup"
                                   Placement="Bottom"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True"
                                   Focusable="False"
                                   PopupAnimation="Fade">
                                <Grid Name="DropDown"
                                      SnapsToDevicePixels="True"
                                      MinWidth="{TemplateBinding ActualWidth}"
                                      MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                    <Border Name="DropDownBorder"
                                            Background="{StaticResource SurfaceBrush}"
                                            BorderThickness="1"
                                            BorderBrush="{StaticResource BorderBrush}"
                                            CornerRadius="4"
                                            Margin="0,2,0,0">
                                        <Border.Effect>
                                            <DropShadowEffect ShadowDepth="4" Opacity="0.4" BlurRadius="8"/>
                                        </Border.Effect>
                                        <ScrollViewer Margin="2" SnapsToDevicePixels="True">
                                            <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                        </ScrollViewer>
                                    </Border>
                                </Grid>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border Name="Border" Background="Transparent" CornerRadius="3" Padding="{TemplateBinding Padding}" Margin="2,1">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{StaticResource AccentBrush}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#FF35353D"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Style Label -->
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{StaticResource TextPrimaryBrush}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="0,2"/>
        </Style>

        <!-- Style CheckBox -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Margin" Value="0,2"/>
        </Style>

        <!-- Style GroupBox -->
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="{StaticResource TextSecondaryBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="Margin" Value="0,4"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="GroupBox">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Border Grid.Row="0" Background="{StaticResource SurfaceAltBrush}"
                                    CornerRadius="4,4,0,0"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="1,1,1,0"
                                    Padding="10,6">
                                <ContentPresenter ContentSource="Header"
                                                  TextBlock.Foreground="{StaticResource TextSecondaryBrush}"
                                                  TextBlock.FontWeight="SemiBold"
                                                  TextBlock.FontSize="11"/>
                            </Border>
                            <Border Grid.Row="1" Background="{StaticResource SurfaceBrush}"
                                    CornerRadius="0,0,4,4"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="1,0,1,1"
                                    Padding="{TemplateBinding Padding}">
                                <ContentPresenter/>
                            </Border>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Style GridSplitter -->
        <Style TargetType="GridSplitter">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Stretch"/>
        </Style>

    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- ============================================ -->
        <!-- HEADER BAR                                   -->
        <!-- ============================================ -->
        <Border Grid.Row="0" Background="{StaticResource SurfaceBrush}" Padding="16,10" BorderThickness="0,0,0,1" BorderBrush="{StaticResource BorderBrush}">
            <DockPanel>
                <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="WinRM" FontSize="18" FontWeight="Bold" Foreground="{StaticResource AccentBrush}" VerticalAlignment="Center"/>
                    <TextBlock Text="Remote Command Tool" FontSize="14" Foreground="{StaticResource TextSecondaryBrush}" Margin="10,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                    <Button Name="btnCred" Content="Identifiants" Style="{StaticResource SecondaryButton}" ToolTip="Configurer les identifiants de connexion (carte a puce)"/>
                    <TextBlock Name="txtCredUser" Text="" Foreground="{StaticResource TextMutedBrush}" FontSize="11" VerticalAlignment="Center" Margin="8,0,0,0"/>
                </StackPanel>
            </DockPanel>
        </Border>

        <!-- ============================================ -->
        <!-- MAIN CONTENT                                 -->
        <!-- ============================================ -->
        <Grid Grid.Row="1" Margin="10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="340" MinWidth="260"/>
                <ColumnDefinition Width="5"/>
                <ColumnDefinition Width="*" MinWidth="400"/>
            </Grid.ColumnDefinitions>

            <!-- ========================================== -->
            <!-- LEFT PANEL: Gestion des serveurs           -->
            <!-- ========================================== -->
            <Grid Grid.Column="0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Titre + compteur serveurs -->
                <DockPanel Grid.Row="0" Margin="0,0,0,6">
                    <Label DockPanel.Dock="Left" Content="Serveurs" FontSize="14" FontWeight="SemiBold"/>
                    <Label Name="lblServerCount" DockPanel.Dock="Right" Content="0 serveur(s)" HorizontalAlignment="Right"
                           Foreground="{StaticResource TextMutedBrush}" FontSize="11"/>
                </DockPanel>

                <!-- Filtre rapide -->
                <TextBox Grid.Row="1" Name="txtFilter" Margin="0,0,0,6"
                         Tag="Filtrer la liste..."
                         FontFamily="Segoe UI" FontSize="12"/>

                <!-- Liste des serveurs -->
                <ListBox Grid.Row="2" Name="lstServers" SelectionMode="Extended" Margin="0,0,0,6"/>

                <!-- Actions sur la liste -->
                <UniformGrid Grid.Row="3" Columns="3" Margin="0,0,0,6">
                    <Button Name="btnSelectAll" Content="Tout" Style="{StaticResource SecondaryButton}" ToolTip="Tout selectionner"/>
                    <Button Name="btnClearSel" Content="Aucun" Style="{StaticResource SecondaryButton}" ToolTip="Deselectionner tout"/>
                    <Button Name="btnExportSel" Content="Exporter" Style="{StaticResource SecondaryButton}" ToolTip="Exporter la selection dans un fichier texte"/>
                </UniformGrid>

                <!-- Recherche AD -->
                <GroupBox Grid.Row="4" Header="RECHERCHE ACTIVE DIRECTORY">
                    <StackPanel>
                        <TextBox Name="txtSearch" Text="*" Margin="0,0,0,6"/>
                        <CheckBox Name="chkServersOnly" Content="Windows Server uniquement" IsChecked="True" Margin="0,0,0,6"/>
                        <Button Name="btnSearch" Content="Rechercher dans la foret" HorizontalAlignment="Stretch"
                                ToolTip="Rechercher des ordinateurs dans la foret Active Directory"/>
                    </StackPanel>
                </GroupBox>

                <!-- Ajout/Suppression manuelle -->
                <GroupBox Grid.Row="5" Header="GESTION MANUELLE">
                    <StackPanel>
                        <TextBox Name="txtNewServer" Margin="0,0,0,6" Tag="Nom du serveur..."/>
                        <UniformGrid Columns="3">
                            <Button Name="btnAdd" Content="Ajouter" ToolTip="Ajouter un serveur (Entree)"/>
                            <Button Name="btnRemove" Content="Supprimer" Style="{StaticResource SecondaryButton}" ToolTip="Supprimer les serveurs selectionnes"/>
                            <Button Name="btnLoad" Content="Importer" Style="{StaticResource SecondaryButton}" ToolTip="Importer des serveurs depuis un fichier texte"/>
                        </UniformGrid>
                    </StackPanel>
                </GroupBox>

                <!-- Test WinRM -->
                <Button Grid.Row="6" Name="btnTest" Content="Tester la connectivite WinRM" HorizontalAlignment="Stretch" Margin="0,6,0,0"
                        Style="{StaticResource SecondaryButton}" ToolTip="Tester la connexion WinRM sur les serveurs selectionnes (ou tous)"/>
            </Grid>

            <!-- GridSplitter -->
            <GridSplitter Grid.Column="1" Width="5" ResizeBehavior="PreviousAndNext" Cursor="SizeWE"/>

            <!-- ========================================== -->
            <!-- RIGHT PANEL: Commande et Sortie            -->
            <!-- ========================================== -->
            <Grid Grid.Column="2" Margin="5,0,0,0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- Presets -->
                <GroupBox Grid.Row="0" Header="COMMANDES PREDEFINIES">
                    <ComboBox Name="cmbPresets" ToolTip="Selectionner une commande predifinie de maintenance"/>
                </GroupBox>

                <!-- Zone de commande -->
                <GroupBox Grid.Row="1" Header="COMMANDE POWERSHELL">
                    <TextBox Name="txtCmd"
                             TextWrapping="Wrap"
                             AcceptsReturn="True"
                             VerticalScrollBarVisibility="Auto"
                             Height="150"
                             FontFamily="Consolas"
                             FontSize="12"/>
                </GroupBox>

                <!-- Boutons d'action -->
                <Grid Grid.Row="2" Margin="0,4,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Button Grid.Column="0" Name="btnRun" Content="Executer" Width="160" Height="36" FontSize="13" FontWeight="SemiBold"
                            ToolTip="Executer la commande sur les serveurs selectionnes (Ctrl+Entree)"/>
                    <Button Grid.Column="1" Name="btnCancel" Content="Annuler" Width="100" Height="36" IsEnabled="False"
                            Style="{StaticResource DangerButton}" ToolTip="Annuler toutes les taches en cours"/>
                    <Button Grid.Column="3" Name="btnCopy" Content="Copier" Height="36"
                            Style="{StaticResource SecondaryButton}" ToolTip="Copier la sortie dans le presse-papiers"/>
                    <Button Grid.Column="4" Name="btnClear" Content="Effacer" Height="36"
                            Style="{StaticResource SecondaryButton}" ToolTip="Effacer la zone de sortie"/>
                </Grid>

                <!-- Barre de progression -->
                <ProgressBar Grid.Row="3" Name="progressBar" Height="3" Margin="0,0,0,4"
                             Visibility="Collapsed"
                             Foreground="{StaticResource AccentBrush}"
                             Background="{StaticResource SurfaceAltBrush}"
                             BorderThickness="0"/>

                <!-- Zone de sortie -->
                <Border Grid.Row="4" Background="{StaticResource TerminalBgBrush}"
                        BorderBrush="{StaticResource BorderBrush}" BorderThickness="1" CornerRadius="4">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Border Grid.Row="0" Background="{StaticResource SurfaceAltBrush}"
                                CornerRadius="4,4,0,0" Padding="10,5">
                            <TextBlock Text="Sortie" Foreground="{StaticResource TextSecondaryBrush}" FontSize="11" FontWeight="SemiBold"/>
                        </Border>
                        <TextBox Grid.Row="1" Name="txtOut"
                                 IsReadOnly="True"
                                 TextWrapping="Wrap"
                                 VerticalScrollBarVisibility="Auto"
                                 Background="Transparent"
                                 Foreground="#FF33FF33"
                                 BorderThickness="0"
                                 FontFamily="Cascadia Mono, Consolas, Courier New"
                                 FontSize="11"
                                 Padding="10,8"/>
                    </Grid>
                </Border>
            </Grid>
        </Grid>

        <!-- ============================================ -->
        <!-- STATUS BAR                                   -->
        <!-- ============================================ -->
        <Border Grid.Row="2" Background="{StaticResource SurfaceBrush}" Padding="12,5" BorderThickness="0,1,0,0" BorderBrush="{StaticResource BorderBrush}">
            <DockPanel>
                <Label Name="lblStatus" DockPanel.Dock="Left" Content="Pret." Foreground="{StaticResource TextSecondaryBrush}" FontSize="11"/>
                <TextBlock DockPanel.Dock="Right" Text="v3.0" Foreground="{StaticResource TextMutedBrush}" FontSize="10" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </DockPanel>
        </Border>
    </Grid>
</Window>
"@

function Build-Form {
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Get all named elements
    $script:lstServers   = $window.FindName("lstServers")
    $script:lblServerCount = $window.FindName("lblServerCount")
    $script:txtFilter    = $window.FindName("txtFilter")
    $script:btnSelectAll = $window.FindName("btnSelectAll")
    $script:btnClearSel  = $window.FindName("btnClearSel")
    $script:btnExportSel = $window.FindName("btnExportSel")
    $script:txtSearch    = $window.FindName("txtSearch")
    $script:chkServersOnly = $window.FindName("chkServersOnly")
    $script:btnSearch    = $window.FindName("btnSearch")
    $script:txtNewServer = $window.FindName("txtNewServer")
    $script:btnAdd       = $window.FindName("btnAdd")
    $script:btnRemove    = $window.FindName("btnRemove")
    $script:btnLoad      = $window.FindName("btnLoad")
    $script:btnTest      = $window.FindName("btnTest")
    $script:btnCred      = $window.FindName("btnCred")
    $script:txtCredUser  = $window.FindName("txtCredUser")
    $script:txtCmd       = $window.FindName("txtCmd")
    $script:cmbPresets   = $window.FindName("cmbPresets")
    $script:btnRun       = $window.FindName("btnRun")
    $script:btnCancel    = $window.FindName("btnCancel")
    $script:btnCopy      = $window.FindName("btnCopy")
    $script:btnClear     = $window.FindName("btnClear")
    $script:txtOut       = $window.FindName("txtOut")
    $script:lblStatus    = $window.FindName("lblStatus")
    $script:progressBar  = $window.FindName("progressBar")

    # -----------------------------------------------------------------
    # Presets de maintenance systeme (categorises)
    # -----------------------------------------------------------------
    $presetCmds = @(
        @{Name="-- Selectionner une commande predifinie --"; Cmd=""; Cat=""},

        @{Name="[Services] Redemarrer Zabbix Agent"; Cmd="Restart-Service -Name 'Zabbix Agent 2' -Force -PassThru"; Cat="Services"},
        @{Name="[Services] Redemarrer Windows Update"; Cmd="Restart-Service -Name 'wuauserv' -Force -PassThru"; Cat="Services"},
        @{Name="[Services] Redemarrer le spouleur d'impression"; Cmd="Restart-Service -Name 'Spooler' -Force -PassThru"; Cat="Services"},
        @{Name="[Services] Services automatiques arretes"; Cmd="Get-Service | Where-Object {`$_.Status -eq 'Stopped' -and `$_.StartType -eq 'Automatic'} | Select-Object Name,DisplayName,Status"; Cat="Services"},

        @{Name="[Processus] Tuer Windows Search (SearchIndexer)"; Cmd="taskkill /f /im SearchIndexer.exe"; Cat="Processus"},
        @{Name="[Processus] Redemarrer l'Explorateur Windows"; Cmd="Stop-Process -Name 'explorer' -Force; Start-Sleep -Seconds 2; Start-Process explorer; Write-Host 'Explorateur redémarre'"; Cat="Processus"},
        @{Name="[Processus] Top 10 consommateurs memoire"; Cmd="Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 10 Name, @{Name='Memoire(MB)';Expression={[math]::Round(`$_.WorkingSet/1MB,2)}}, Id"; Cat="Processus"},
        @{Name="[Processus] Top 10 consommateurs CPU"; Cmd="Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, CPU, Id"; Cat="Processus"},

        @{Name="[Reseau] Vider le cache DNS client"; Cmd="Clear-DnsClientCache; Write-Host 'Cache DNS vide'"; Cat="Reseau"},
        @{Name="[Reseau] Vider le DNS (ipconfig)"; Cmd="ipconfig /flushdns"; Cat="Reseau"},
        @{Name="[Reseau] Reinitialiser Winsock"; Cmd="netsh winsock reset"; Cat="Reseau"},
        @{Name="[Reseau] Adaptateurs reseau IPv4"; Cmd="Get-NetIPAddress | Where-Object {`$_.AddressFamily -eq 'IPv4'} | Select-Object InterfaceAlias, IPAddress, PrefixLength"; Cat="Reseau"},
        @{Name="[Reseau] Test connectivite (Google DNS)"; Cmd="Test-NetConnection -ComputerName 8.8.8.8 -InformationLevel Detailed"; Cat="Reseau"},

        @{Name="[Systeme] Forcer la mise a jour des GPO"; Cmd="gpupdate /force"; Cat="Systeme"},
        @{Name="[Systeme] Utilisation espace disque"; Cmd="Get-WmiObject Win32_LogicalDisk | Select-Object DeviceID, @{Name='EspaceLibre(GB)';Expression={[math]::Round(`$_.FreeSpace/1GB,2)}}, @{Name='Taille(GB)';Expression={[math]::Round(`$_.Size/1GB,2)}}, @{Name='%Libre';Expression={[math]::Round((`$_.FreeSpace/`$_.Size)*100,1)}}"; Cat="Systeme"},
        @{Name="[Systeme] Uptime du systeme"; Cmd="`$os = Get-WmiObject Win32_OperatingSystem; `$uptime = (Get-Date) - `$os.ConvertToDateTime(`$os.LastBootUpTime); Write-Output ('Uptime: {0} jours, {1} heures, {2} minutes' -f `$uptime.Days, `$uptime.Hours, `$uptime.Minutes)"; Cat="Systeme"},
        @{Name="[Systeme] Resume informations systeme"; Cmd="`$cs = Get-WmiObject Win32_ComputerSystem; `$os = Get-WmiObject Win32_OperatingSystem; [PSCustomObject]@{Ordinateur=`$cs.Name; OS=`$os.Caption; Version=`$os.Version; 'RAM(GB)'=[math]::Round(`$cs.TotalPhysicalMemory/1GB,2); Domaine=`$cs.Domain} | Format-List"; Cat="Systeme"},
        @{Name="[Systeme] Erreurs systeme recentes (50)"; Cmd="Get-EventLog -LogName System -EntryType Error -Newest 50 | Select-Object TimeGenerated,Source,EventID,Message"; Cat="Systeme"},

        @{Name="[Mises a jour] Derniers correctifs installes"; Cmd="Get-WmiObject -Class Win32_QuickFixEngineering | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, Description, InstalledOn"; Cat="Mises a jour"},
        @{Name="[Mises a jour] Vider le cache Windows Update"; Cmd="Stop-Service -Name 'wuauserv' -Force; Remove-Item -Path 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -ErrorAction SilentlyContinue; Start-Service -Name 'wuauserv'; Write-Host 'Cache Windows Update vide'"; Cat="Mises a jour"},

        @{Name="[Nettoyage] Vider les dossiers temporaires"; Cmd="Remove-Item -Path `$env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue; Write-Host 'Dossiers temporaires nettoyes'"; Cat="Nettoyage"},

        @{Name="[DANGER] REDEMARRER L'ORDINATEUR (Force)"; Cmd="Restart-Computer -Force"; Cat="Danger"}
    )

    foreach ($preset in $presetCmds) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $preset.Name
        $item.Tag = $preset.Cmd
        if ($preset.Cat -eq "Danger") {
            $item.Foreground = [System.Windows.Media.Brushes]::Tomato
            $item.FontWeight = "Bold"
        }
        $null = $script:cmbPresets.Items.Add($item)
    }
    $script:cmbPresets.SelectedIndex = 0

    # -----------------------------------------------------------------
    # Event Handlers
    # -----------------------------------------------------------------

    # Filtre dynamique sur la liste des serveurs
    $script:allServers = New-Object System.Collections.Generic.List[string]

    $script:txtFilter.Add_TextChanged({
        $filter = $script:txtFilter.Text.Trim()
        $script:lstServers.Items.Clear()
        foreach ($sv in $script:allServers) {
            if ([string]::IsNullOrEmpty($filter) -or $sv -like "*$filter*") {
                $null = $script:lstServers.Items.Add($sv)
            }
        }
        Update-ServerCount
    })

    # Mise a jour du compteur lors de la selection
    $script:lstServers.Add_SelectionChanged({
        Update-ServerCount
    })

    $script:btnSelectAll.Add_Click({
        $script:lstServers.SelectAll()
    })

    $script:btnClearSel.Add_Click({
        $script:lstServers.UnselectAll()
    })

    $script:btnExportSel.Add_Click({
        if (Export-Selection -List $script:lstServers) {
            Append-Log $script:txtOut "Selection exportee avec succes.`r`n"
            Update-StatusBar "Export termine." "Success"
        } else {
            Append-Log $script:txtOut "Export annule ou echoue.`r`n"
        }
    })

    # Ajouter un serveur (fonction reutilisable)
    $addServerAction = {
        $name = $script:txtNewServer.Text.Trim()
        if ($name -and -not $script:allServers.Contains($name)) {
            $null = $script:allServers.Add($name)
            $filter = $script:txtFilter.Text.Trim()
            if ([string]::IsNullOrEmpty($filter) -or $name -like "*$filter*") {
                $null = $script:lstServers.Items.Add($name)
            }
            Append-Log $script:txtOut "Ajoute : $name`r`n"
            Update-ServerCount
            Update-StatusBar "Serveur '$name' ajoute." "Success"
        }
        $script:txtNewServer.Text = ""
        $script:txtNewServer.Focus()
    }

    $script:btnAdd.Add_Click($addServerAction)

    # Enter dans le champ nouveau serveur = ajouter
    $script:txtNewServer.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Return') {
            $addServerAction.Invoke()
            $e.Handled = $true
        }
    })

    $script:btnRemove.Add_Click({
        $selected = @($script:lstServers.SelectedItems)
        foreach ($item in $selected) {
            $script:lstServers.Items.Remove($item)
            $script:allServers.Remove($item) | Out-Null
        }
        if ($selected.Count -gt 0) {
            Append-Log $script:txtOut "Supprime $($selected.Count) serveur(s).`r`n"
            Update-ServerCount
            Update-StatusBar "$($selected.Count) serveur(s) supprime(s)." "Info"
        }
    })

    $script:btnLoad.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = "Text files (*.txt)|*.txt|CSV files (*.csv)|*.csv|All files (*.*)|*.*"
        if ($dlg.ShowDialog() -ne $true) { return }
        $lines = @()
        try { $lines = Get-Content -Path $dlg.FileName -ErrorAction Stop } catch { return }
        $added = 0
        foreach ($l in $lines) {
            $sv = ([string]$l).Trim()
            if ($sv -and -not $script:allServers.Contains($sv)) {
                $null = $script:allServers.Add($sv)
                $null = $script:lstServers.Items.Add($sv)
                $added++
            }
        }
        Append-Log $script:txtOut "Fusionne $added serveur(s) depuis '$($dlg.FileName)'.`r`n"
        Update-ServerCount
        Update-StatusBar "$added serveur(s) importe(s)." "Success"
    })

    $script:btnTest.Add_Click({
        $targets = if ($script:lstServers.SelectedItems.Count -gt 0) {
            @($script:lstServers.SelectedItems)
        } else {
            @($script:lstServers.Items)
        }
        if ($targets.Count -eq 0) {
            Append-Log $script:txtOut "Aucun serveur a tester.`r`n"
            Update-StatusBar "Aucun serveur a tester." "Warning"
            return
        }
        Append-Log $script:txtOut "`r`nTest WinRM sur $($targets.Count) serveur(s)...`r`n"
        Update-StatusBar "Test WinRM en cours..." "Warning"
        Test-Servers -Servers $targets -OutputBox $script:txtOut
    })

    $script:btnCred.Add_Click({
        Get-AppCredential
        if ($global:Cred) {
            $script:txtCredUser.Text = $global:Cred.UserName
            Append-Log $script:txtOut "Identifiants captures pour : $($global:Cred.UserName)`r`n"
            Update-StatusBar "Identifiants configures." "Success"
        }
    })

    $script:cmbPresets.Add_SelectionChanged({
        if ($script:cmbPresets.SelectedIndex -gt 0) {
            $selected = $script:cmbPresets.SelectedItem
            if ($selected.Tag) {
                $script:txtCmd.Text = $selected.Tag
            }
        }
    })

    # Execution de commande
    $runCommandAction = {
        $targets = if ($script:lstServers.SelectedItems.Count -gt 0) {
            @($script:lstServers.SelectedItems)
        } else {
            @($script:lstServers.Items)
        }
        if ($targets.Count -eq 0) {
            Append-Log $script:txtOut "Aucun serveur selectionne.`r`n"
            Update-StatusBar "Aucun serveur selectionne." "Warning"
            return
        }
        if ([string]::IsNullOrWhiteSpace($script:txtCmd.Text)) {
            Append-Log $script:txtOut "Aucune commande specifiee.`r`n"
            Update-StatusBar "Aucune commande specifiee." "Warning"
            return
        }

        # Confirmation pour les commandes dangereuses
        $cmd = $script:txtCmd.Text
        $dangerousPatterns = @('Restart-Computer', 'Stop-Computer', 'Remove-Item C:\\Windows', 'Format-Volume', 'Clear-Disk')
        $isDangerous = $false
        foreach ($pattern in $dangerousPatterns) {
            if ($cmd -match [regex]::Escape($pattern)) { $isDangerous = $true; break }
        }
        if ($isDangerous) {
            $result = [System.Windows.MessageBox]::Show(
                "Cette commande est potentiellement dangereuse :`n`n$cmd`n`nEtes-vous sur de vouloir l'executer sur $($targets.Count) serveur(s) ?",
                "Confirmation requise",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
                Append-Log $script:txtOut "Execution annulee par l'utilisateur.`r`n"
                Update-StatusBar "Execution annulee." "Info"
                return
            }
        }

        Append-Log $script:txtOut ("`r`n{'='*50}`r`n")
        Append-Log $script:txtOut "Demarrage sur $($targets.Count) serveur(s)...`r`n"
        Append-Log $script:txtOut ("{'='*50}`r`n")
        Start-CommandJobs -Servers $targets -Command $cmd -OutputBox $script:txtOut -RunButton $script:btnRun -CancelButton $script:btnCancel
    }

    $script:btnRun.Add_Click($runCommandAction)

    # Ctrl+Enter dans la zone de commande = executer
    $script:txtCmd.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Return' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            $runCommandAction.Invoke()
            $e.Handled = $true
        }
    })

    $script:btnCancel.Add_Click({
        Stop-CommandJobs
        $script:btnRun.IsEnabled = $true
        $script:btnCancel.IsEnabled = $false
        Append-Log $script:txtOut "Taches annulees.`r`n"
        Update-StatusBar "Taches annulees." "Warning"
    })

    $script:btnCopy.Add_Click({
        if (-not [string]::IsNullOrEmpty($script:txtOut.Text)) {
            [System.Windows.Clipboard]::SetText($script:txtOut.Text)
            Update-StatusBar "Sortie copiee dans le presse-papiers." "Success"
        }
    })

    $script:btnClear.Add_Click({
        $script:txtOut.Text = ""
        Update-StatusBar "Sortie effacee." "Info"
    })

    $script:btnSearch.Add_Click({
        $pat = $script:txtSearch.Text
        if ([string]::IsNullOrWhiteSpace($pat)) { $pat = "*" }
        Append-Log $script:txtOut "Recherche dans la foret AD avec le motif : '$pat'...`r`n"
        Update-StatusBar "Recherche AD en cours..." "Warning"
        $servers = Find-ServersInForest -Pattern $pat -ServersOnly:($script:chkServersOnly.IsChecked)
        if (-not $servers -or $servers.Count -eq 0) {
            Append-Log $script:txtOut "Aucune correspondance trouvee.`r`n"
            Update-StatusBar "Aucun resultat AD." "Warning"
        } else {
            $added = 0
            foreach ($sv in $servers) {
                if (-not $script:allServers.Contains($sv)) {
                    $null = $script:allServers.Add($sv)
                    $null = $script:lstServers.Items.Add($sv)
                    $added++
                }
            }
            Append-Log $script:txtOut "Trouve $($servers.Count) serveur(s), ajoute $added nouveau(x).`r`n"
            Update-ServerCount
            Update-StatusBar "Recherche AD terminee : $added ajoute(s)." "Success"
        }
    })

    $window.Add_Closing({
        Stop-CommandJobs
    })

    # Message de bienvenue
    Append-Log $script:txtOut "WinRM Remote Command Tool v3.0`r`n"
    Append-Log $script:txtOut ("{'='*50}`r`n")
    Append-Log $script:txtOut "Raccourcis :`r`n"
    Append-Log $script:txtOut "  Ctrl+Entree  : Executer la commande`r`n"
    Append-Log $script:txtOut "  Entree       : Ajouter un serveur (dans le champ)`r`n"
    Append-Log $script:txtOut ("{'='*50}`r`n`r`n")

    Update-ServerCount
    Update-StatusBar "Pret. Ajoutez des serveurs pour commencer." "Info"

    return $window
}

# Point d'entree - Assurer le mode STA
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    Write-Host "Redemarrage en mode STA..."
    Start-Process -FilePath powershell.exe -ArgumentList "-STA -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -WindowStyle Normal
    return
}

$window = Build-Form
$null = $window.ShowDialog()
