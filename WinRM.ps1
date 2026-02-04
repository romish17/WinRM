#requires -Version 5.1
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$global:Cred = $null
$global:Jobs = @()
$global:JobTimer = $null

function Get-AppCredential { # One-shot smartcard credential
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
            if ($global:Jobs.Count -gt 0 -and $done.Count -eq $global:Jobs.Count) {
                foreach ($dj in $global:Jobs) { Remove-Job -Job $dj -Force -ErrorAction SilentlyContinue }
                $global:Jobs = @()
                $script:btnRun.IsEnabled = $true
                $script:btnCancel.IsEnabled = $false
                Append-Log $script:txtOut "Toutes les tâches sont terminées.`r`n"
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
}

function Test-Servers {
    param([string[]]$Servers, [System.Windows.Controls.TextBox]$OutputBox)
    foreach ($s in $Servers) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $ok = $false
        try { Test-WSMan -ComputerName $s -ErrorAction Stop | Out-Null; $ok = $true } catch { $ok = $false }
        $msg = if ($ok) { "[OK] " } else { "[KO] " }
        Append-Log $OutputBox ($msg + $s + "`r`n")
    }
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
    $dlg.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
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

# XAML Interface Definition
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinRM Commande à Distance - Outil de Maintenance Système"
        Height="750" Width="1200"
        WindowStartupLocation="CenterScreen"
        Background="#FF2D2D30">

    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#FF007ACC"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="Margin" Value="2"/>
            <Setter Property="FontSize" Value="12"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#FF1C97EA"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#FF3E3E42"/>
                    <Setter Property="Foreground" Value="#FF999999"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#FF3E3E42"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF555555"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="11"/>
        </Style>

        <Style TargetType="ListBox">
            <Setter Property="Background" Value="#FF1E1E1E"/>
            <Setter Property="Foreground" Value="#FFFFCC00"/>
            <Setter Property="BorderBrush" Value="#FF555555"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="11"/>
        </Style>

        <Style TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="#FFFFCC00"/>
            <Setter Property="Background" Value="Transparent"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#FF007ACC"/>
                    <Setter Property="Foreground" Value="White"/>
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#FF3E3E42"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#FF555555"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="Background" Value="#FF3E3E42"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton Name="ToggleButton"
                                          Background="#FF3E3E42"
                                          BorderBrush="{TemplateBinding BorderBrush}"
                                          BorderThickness="{TemplateBinding BorderThickness}"
                                          Focusable="False"
                                          IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition/>
                                        <ColumnDefinition Width="20"/>
                                    </Grid.ColumnDefinitions>
                                    <ContentPresenter Grid.Column="0" Name="ContentSite"
                                                    Content="{TemplateBinding SelectionBoxItem}"
                                                    ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                                    ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                                    VerticalAlignment="Center"
                                                    HorizontalAlignment="Left"
                                                    Margin="5,0,0,0"/>
                                    <Path Grid.Column="1" Name="Arrow"
                                          Fill="White"
                                          HorizontalAlignment="Center"
                                          VerticalAlignment="Center"
                                          Data="M 0 0 L 4 4 L 8 0 Z"/>
                                </Grid>
                            </ToggleButton>
                            <Popup Name="Popup"
                                   Placement="Bottom"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   AllowsTransparency="True"
                                   Focusable="False"
                                   PopupAnimation="Slide">
                                <Grid Name="DropDown"
                                      SnapsToDevicePixels="True"
                                      MinWidth="{TemplateBinding ActualWidth}"
                                      MaxHeight="{TemplateBinding MaxDropDownHeight}">
                                    <Border Name="DropDownBorder" Background="#FF2D2D30" BorderThickness="1" BorderBrush="#FF555555"/>
                                    <ScrollViewer Margin="2" SnapsToDevicePixels="True">
                                        <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                                    </ScrollViewer>
                                </Grid>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border Name="Border" Background="#FF2D2D30" BorderThickness="0" Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#FF007ACC"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="#FF007ACC"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#FFE0E0E0"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#FFE0E0E0"/>
            <Setter Property="FontSize" Value="11"/>
        </Style>
    </Window.Resources>

    <Grid Margin="10">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="360"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Left Panel: Server Management -->
        <Border Grid.Column="0" Background="#FF1E1E1E" Padding="10" Margin="0,0,5,0" CornerRadius="4">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Label Grid.Row="0" Content="Liste des Serveurs" FontSize="14" Margin="0,0,0,5"/>

                <ListBox Grid.Row="1" Name="lstServers" SelectionMode="Extended" Margin="0,0,0,10"/>

                <!-- Server List Actions -->
                <WrapPanel Grid.Row="2" Margin="0,0,0,10">
                    <Button Name="btnSelectAll" Content="Tout sélectionner" Width="110"/>
                    <Button Name="btnClearSel" Content="Effacer" Width="70"/>
                    <Button Name="btnExportSel" Content="Exporter" Width="80"/>
                </WrapPanel>

                <!-- AD Search -->
                <StackPanel Grid.Row="3" Margin="0,0,0,10">
                    <Label Content="Recherche dans la forêt Active Directory" FontSize="11"/>
                    <TextBox Name="txtSearch" Text="*" Margin="0,0,0,5"/>
                    <CheckBox Name="chkServersOnly" Content="Windows Server uniquement" IsChecked="True" Margin="0,0,0,5"/>
                    <Button Name="btnSearch" Content="Rechercher AD" HorizontalAlignment="Stretch"/>
                </StackPanel>

                <!-- Manual Add/Remove -->
                <StackPanel Grid.Row="4" Margin="0,0,0,10">
                    <Label Content="Entrée manuelle" FontSize="11"/>
                    <TextBox Name="txtNewServer" Margin="0,0,0,5"/>
                    <UniformGrid Columns="2" Rows="1">
                        <Button Name="btnAdd" Content="Ajouter" Margin="0,0,2,0"/>
                        <Button Name="btnRemove" Content="Supprimer" Margin="2,0,0,0"/>
                    </UniformGrid>
                </StackPanel>

                <!-- Import/Test/Credential -->
                <UniformGrid Grid.Row="5" Columns="2" Rows="2" Margin="0,0,0,10">
                    <Button Name="btnLoad" Content="Importer" Margin="0,0,2,2"/>
                    <Button Name="btnTest" Content="Tester WinRM" Margin="2,0,0,2"/>
                    <Button Name="btnCred" Content="Identifiants" Grid.ColumnSpan="2" Margin="0,2,0,0"/>
                </UniformGrid>

                <TextBlock Grid.Row="6" Text="v2.0 - Édition XAML" Foreground="#FF666666" FontSize="9" HorizontalAlignment="Right"/>
            </Grid>
        </Border>

        <!-- Right Panel: Command and Output -->
        <Grid Grid.Column="1">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="240"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <Label Grid.Row="0" Content="Commande PowerShell" FontSize="14" Margin="0,0,0,5"/>

            <TextBox Grid.Row="1" Name="txtCmd"
                     TextWrapping="Wrap"
                     AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto"
                     Margin="0,0,0,10"/>

            <Label Grid.Row="2" Content="Commandes prédéfinies - Maintenance Système" FontSize="11" Margin="0,0,0,5"/>

            <ComboBox Grid.Row="3" Name="cmbPresets" Margin="0,0,0,10"/>

            <WrapPanel Grid.Row="4" Margin="0,0,0,10">
                <Button Name="btnRun" Content="Exécuter sur Sélection/Tous" Width="180" Height="35" FontSize="13" FontWeight="Bold"/>
                <Button Name="btnCancel" Content="Annuler" Width="100" Height="35" IsEnabled="False" Background="#FFCC0000"/>
                <Button Name="btnClear" Content="Effacer Sortie" Width="120" Height="35" Background="#FF555555"/>
            </WrapPanel>

            <Border Grid.Row="5" Background="#FF0C0C0C" BorderBrush="#FF555555" BorderThickness="1" CornerRadius="4">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <Label Grid.Row="0" Content="Sortie de Commande" Background="#FF1A1A1A" Margin="0"/>
                    <TextBox Grid.Row="1" Name="txtOut"
                             IsReadOnly="True"
                             TextWrapping="Wrap"
                             VerticalScrollBarVisibility="Auto"
                             Background="#FF0C0C0C"
                             Foreground="#FF00FF00"
                             FontFamily="Consolas"
                             FontSize="10"
                             Padding="5"/>
                </Grid>
            </Border>
        </Grid>
    </Grid>
</Window>
"@

function Build-Form {
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Get all named elements
    $script:lstServers = $window.FindName("lstServers")
    $script:btnSelectAll = $window.FindName("btnSelectAll")
    $script:btnClearSel = $window.FindName("btnClearSel")
    $script:btnExportSel = $window.FindName("btnExportSel")
    $script:txtSearch = $window.FindName("txtSearch")
    $script:chkServersOnly = $window.FindName("chkServersOnly")
    $script:btnSearch = $window.FindName("btnSearch")
    $script:txtNewServer = $window.FindName("txtNewServer")
    $script:btnAdd = $window.FindName("btnAdd")
    $script:btnRemove = $window.FindName("btnRemove")
    $script:btnLoad = $window.FindName("btnLoad")
    $script:btnTest = $window.FindName("btnTest")
    $script:btnCred = $window.FindName("btnCred")
    $script:txtCmd = $window.FindName("txtCmd")
    $script:cmbPresets = $window.FindName("cmbPresets")
    $script:btnRun = $window.FindName("btnRun")
    $script:btnCancel = $window.FindName("btnCancel")
    $script:btnClear = $window.FindName("btnClear")
    $script:txtOut = $window.FindName("txtOut")

    # Presets de maintenance système
    $presetCmds = @(
        @{Name="-- Sélectionner un preset de maintenance --"; Cmd=""},
        @{Name="Tuer Windows Search (SearchIndexer)"; Cmd="taskkill /f /im SearchIndexer.exe"},
        @{Name="Redémarrer Zabbix Agent"; Cmd="Restart-Service -Name 'Zabbix Agent 2' -Force -PassThru"},
        @{Name="Forcer la mise à jour des GPO"; Cmd="gpupdate /force"},
        @{Name="Redémarrer l'Explorateur Windows"; Cmd="Stop-Process -Name 'explorer' -Force; Start-Sleep -Seconds 2; Start-Process explorer; Write-Host 'Explorateur redémarré'"},
        @{Name="Vider le cache DNS client"; Cmd="Clear-DnsClientCache; Write-Host 'Cache DNS vidé'"},
        @{Name="Vider le DNS (ipconfig)"; Cmd="ipconfig /flushdns"},
        @{Name="Réinitialiser la pile réseau Winsock"; Cmd="netsh winsock reset"},
        @{Name="Redémarrer le service Windows Update"; Cmd="Restart-Service -Name 'wuauserv' -Force -PassThru"},
        @{Name="Trouver les services automatiques arrêtés"; Cmd="Get-Service | Where-Object {`$_.Status -eq 'Stopped' -and `$_.StartType -eq 'Automatic'} | Select-Object Name,DisplayName,Status"},
        @{Name="Erreurs système récentes (50 dernières)"; Cmd="Get-EventLog -LogName System -EntryType Error -Newest 50 | Select-Object TimeGenerated,Source,EventID,Message"},
        @{Name="Utilisation de l'espace disque"; Cmd="Get-WmiObject Win32_LogicalDisk | Select-Object DeviceID, @{Name='EspaceLibre(GB)';Expression={[math]::Round(`$_.FreeSpace/1GB,2)}}, @{Name='Taille(GB)';Expression={[math]::Round(`$_.Size/1GB,2)}}, @{Name='%Libre';Expression={[math]::Round((`$_.FreeSpace/`$_.Size)*100,1)}}"},
        @{Name="Top 10 consommateurs de mémoire"; Cmd="Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 10 Name, @{Name='Mémoire(MB)';Expression={[math]::Round(`$_.WorkingSet/1MB,2)}}, Id"},
        @{Name="Top 10 consommateurs de CPU"; Cmd="Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, CPU, Id"},
        @{Name="État des adaptateurs réseau IPv4"; Cmd="Get-NetIPAddress | Where-Object {`$_.AddressFamily -eq 'IPv4'} | Select-Object InterfaceAlias, IPAddress, PrefixLength"},
        @{Name="Temps de fonctionnement du système"; Cmd="`$os = Get-WmiObject Win32_OperatingSystem; `$uptime = (Get-Date) - `$os.ConvertToDateTime(`$os.LastBootUpTime); Write-Output ('Uptime: {0} jours, {1} heures, {2} minutes' -f `$uptime.Days, `$uptime.Hours, `$uptime.Minutes)"},
        @{Name="Windows Update - Vérifier les mises à jour"; Cmd="Get-WmiObject -Class Win32_QuickFixEngineering | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, Description, InstalledOn"},
        @{Name="Vider les dossiers temporaires"; Cmd="Remove-Item -Path `$env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue; Write-Host 'Dossiers temporaires nettoyés'"},
        @{Name="Vider le cache Windows Update"; Cmd="Stop-Service -Name 'wuauserv' -Force; Remove-Item -Path 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -ErrorAction SilentlyContinue; Start-Service -Name 'wuauserv'; Write-Host 'Cache Windows Update vidé'"},
        @{Name="Redémarrer le spouleur d'impression"; Cmd="Restart-Service -Name 'Spooler' -Force -PassThru"},
        @{Name="Test de connectivité réseau (Google DNS)"; Cmd="Test-NetConnection -ComputerName 8.8.8.8 -InformationLevel Detailed"},
        @{Name="Résumé des informations système"; Cmd="`$cs = Get-WmiObject Win32_ComputerSystem; `$os = Get-WmiObject Win32_OperatingSystem; [PSCustomObject]@{Ordinateur=`$cs.Name; OS=`$os.Caption; Version=`$os.Version; 'RAM(GB)'=[math]::Round(`$cs.TotalPhysicalMemory/1GB,2); Domaine=`$cs.Domain} | Format-List"},
        @{Name="REDÉMARRER L'ORDINATEUR (Forcé)"; Cmd="Restart-Computer -Force"}
    )

    foreach ($preset in $presetCmds) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $preset.Name
        $item.Tag = $preset.Cmd
        $null = $script:cmbPresets.Items.Add($item)
    }
    $script:cmbPresets.SelectedIndex = 0

    # Event Handlers
    $script:btnSelectAll.Add_Click({
        $script:lstServers.SelectAll()
    })

    $script:btnClearSel.Add_Click({
        $script:lstServers.UnselectAll()
    })

    $script:btnExportSel.Add_Click({
        if (Export-Selection -List $script:lstServers) {
            Append-Log $script:txtOut "Sélection exportée avec succès.`r`n"
        } else {
            Append-Log $script:txtOut "Export annulé ou échoué.`r`n"
        }
    })

    $script:btnAdd.Add_Click({
        $name = $script:txtNewServer.Text.Trim()
        if ($name -and -not $script:lstServers.Items.Contains($name)) {
            $null = $script:lstServers.Items.Add($name)
            Append-Log $script:txtOut "Ajouté : $name`r`n"
        }
        $script:txtNewServer.Text = ""
    })

    $script:btnRemove.Add_Click({
        $selected = @($script:lstServers.SelectedItems)
        foreach ($item in $selected) {
            $script:lstServers.Items.Remove($item)
        }
        if ($selected.Count -gt 0) {
            Append-Log $script:txtOut "Supprimé $($selected.Count) serveur(s).`r`n"
        }
    })

    $script:btnLoad.Add_Click({
        $added = Import-Merge -List $script:lstServers
        Append-Log $script:txtOut "Fusionné $added serveur(s).`r`n"
    })

    $script:btnTest.Add_Click({
        $targets = if ($script:lstServers.SelectedItems.Count -gt 0) {
            @($script:lstServers.SelectedItems)
        } else {
            @($script:lstServers.Items)
        }
        if ($targets.Count -eq 0) {
            Append-Log $script:txtOut "Aucun serveur à tester.`r`n"
            return
        }
        Append-Log $script:txtOut "Test WinRM sur $($targets.Count) serveur(s)...`r`n"
        Test-Servers -Servers $targets -OutputBox $script:txtOut
    })

    $script:btnCred.Add_Click({
        Get-AppCredential
        if ($global:Cred) {
            Append-Log $script:txtOut "Identifiants capturés pour : $($global:Cred.UserName)`r`n"
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

    $script:btnRun.Add_Click({
        $targets = if ($script:lstServers.SelectedItems.Count -gt 0) {
            @($script:lstServers.SelectedItems)
        } else {
            @($script:lstServers.Items)
        }
        if ($targets.Count -eq 0) {
            Append-Log $script:txtOut "Aucun serveur sélectionné.`r`n"
            return
        }
        if ([string]::IsNullOrWhiteSpace($script:txtCmd.Text)) {
            Append-Log $script:txtOut "Aucune commande spécifiée.`r`n"
            return
        }
        Append-Log $script:txtOut "`r`n========================================`r`n"
        Append-Log $script:txtOut "Démarrage des tâches sur $($targets.Count) serveur(s)...`r`n"
        Append-Log $script:txtOut "========================================`r`n"
        Start-CommandJobs -Servers $targets -Command $script:txtCmd.Text -OutputBox $script:txtOut -RunButton $script:btnRun -CancelButton $script:btnCancel
    })

    $script:btnCancel.Add_Click({
        Stop-CommandJobs
        $script:btnRun.IsEnabled = $true
        $script:btnCancel.IsEnabled = $false
        Append-Log $script:txtOut "Tâches annulées.`r`n"
    })

    $script:btnClear.Add_Click({
        $script:txtOut.Text = ""
    })

    $script:btnSearch.Add_Click({
        $pat = $script:txtSearch.Text
        if ([string]::IsNullOrWhiteSpace($pat)) { $pat = "*" }
        Append-Log $script:txtOut "Recherche dans la forêt AD avec le motif : '$pat'...`r`n"
        $servers = Find-ServersInForest -Pattern $pat -ServersOnly:($script:chkServersOnly.IsChecked)
        if (-not $servers -or $servers.Count -eq 0) {
            Append-Log $script:txtOut "Aucune correspondance trouvée.`r`n"
        } else {
            $added = 0
            foreach ($sv in $servers) {
                if (-not $script:lstServers.Items.Contains($sv)) {
                    $null = $script:lstServers.Items.Add($sv)
                    $added++
                }
            }
            Append-Log $script:txtOut "Trouvé $($servers.Count) serveur(s), ajouté $added nouveau(x) serveur(s).`r`n"
        }
    })

    $window.Add_Closing({
        Stop-CommandJobs
    })

    Append-Log $script:txtOut "Outil de Commande à Distance WinRM v2.0 - Édition XAML`r`n"
    Append-Log $script:txtOut "Prêt. Ajoutez des serveurs et exécutez des commandes.`r`n`r`n"

    return $window
}

# Point d'entrée - Assurer le mode STA
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    Write-Host "Redémarrage en mode STA..."
    Start-Process -FilePath powershell.exe -ArgumentList "-STA -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -WindowStyle Normal
    return
}

$window = Build-Form
$null = $window.ShowDialog()
