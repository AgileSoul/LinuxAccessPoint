#!/usr/bin/env bash

if [ $EUID -ne 0 ]; then
    echo -e "\e[31mExiting...\e[0m \e[36mAre you root ?\e[0m"
    exit 1
fi

clear

# Path to the directory containing the executable script
readonly AccessPointPath=$(dirname $(readlink -f $0))
readonly AccessPointLibPath="$AccessPointPath/lib"
# Path to work
readonly AccessPointWorkSpacePath="$AccessPointPath/tmp"
mkdir -p $AccessPointWorkSpacePath/OriginalFiles

# Original files to save later
readonly InterfacesConfigFile="/etc/network/interfaces"
readonly HostapdConfigFile="/etc/hostapd/hostapd.conf"
readonly HostapdDefaultConfigFile="/etc/default/hostapd"
readonly DhcpDefaultConfigFile="/etc/default/isc-dhcp-server"
readonly DhcpServerConfigFile="/etc/dhcp/dhcpd.conf"
readonly NetworkManagerConfigFile="/etc/NetworkManager/NetworkManager.conf"

# ========== < Lib Utils > ============
source "$AccessPointLibPath/resolutionUtils.sh"
source "$AccessPointLibPath/colorUtils.sh"
source "$AccessPointLibPath/fileUtils.sh"

# Access point interface and forwarding interface
readonly InterfaceAccessPoint="wlp3s0"
readonly InterfaceForward="wlxec086b1038e3"

# ========== < Configure Variables > ============
AccessPointState="Not Ready"

check_interfaces_integrity()
{
    local interface
    for interface in "$InterfaceAccessPoint" "$InterfaceForward"
    do
        if ! ifconfig "$interface" &> /dev/null; then
            echo -e "$AccessPointDefaultError the interface [$Verde$interface$TerminarColor] isn't configured, please configure it"
            return 1
        fi
    done

    readonly IpRegex='[0-9]{2,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'

    readonly ForwardIp=$(ifconfig "$InterfaceForward" | grep -E "$IpRegex" | awk '{print $2}')
    if [ ! $ForwardIp ]; then
        echo -e "$AccessPointDefaultError the forward interface [$Verde$InterfaceForward$TerminarColor] hasn't Ip, please connect it to a wifi network"
        return 2
    fi
}

get_network_info()
{
    local -r idVlanForward=$(echo $ForwardIp | cut -d "." -f 3 )
    
    if [  $idVlanForward -gt 244 ]; then
        local -r idVlanAccessPoint=$(($idVlanForward - 10))
    else
        local -r idVlanAccessPoint=$(($idVlanForward + 10))
    fi

    readonly AccessPointIp="$(echo "$ForwardIp" |
      sed -r "s/^([0-9]+\.[0-9]+\.)$idVlanForward\.[0-9]+$/\1$idVlanAccessPoint.1/")"
    readonly AccessPointNetmask="255.255.255.0"
    readonly AccessPointBroadcast="$(echo "$AccessPointIp" | cut -d "." -f 1,2,3).255"
    readonly AccessPointSubnet="${AccessPointIp%.*}.0"
    readonly AccessPointDhcpRange="${AccessPointIp%.*}.2 ${AccessPointIp%.*}.254"
    readonly AccessPointDnsServer="8.8.8.8"
}

set_interfaces_config()
{
    readonly InterfacesConfigCopyFile="$AccessPointWorkSpacePath/OriginalFiles/interfacesOriginal"

    move_file "$InterfacesConfigFile" "$InterfacesConfigCopyFile" set_ 

    local -r configuration=(
      "auto lo" 
      "iface lo inet loopback"
      ""
      "auto $InterfaceAccessPoint" 
      "iface $InterfaceAccessPoint inet static"
      "   address $AccessPointIp" 
      "   netmask $AccessPointNetmask"
      "   broadcast $AccessPointBroadcast" 
    )
    
    generate_config_file "$InterfacesConfigFile" configuration[@]
}

unset_interfaces_config()
{
    move_file "$InterfacesConfigCopyFile" "$InterfacesConfigFile" unset_
}

set_NetworkManager_config()
{
    readonly NetworkManagerConfigCopyFile="$AccessPointWorkSpacePath/OriginalFiles/NetworkManagerOriginal.conf"
    move_file "$NetworkManagerConfigFile" "$NetworkManagerConfigCopyFile" set_

    # generate new config file
    local configuration
    readarray -t configuration < $NetworkManagerConfigCopyFile

    configuration+=( 
      ""
      "[keyfile]"
      "unmanaged-devices=interface-name:$InterfaceAccessPoint"
    )

    generate_config_file "$NetworkManagerConfigFile" configuration[@]
}

unset_NetworkManager_config()
{
    move_file "$NetworkManagerConfigCopyFile" "$NetworkManagerConfigFile" unset_
}

set_hostapd_config()
{
    readonly HostapdDefaultConfigCopyFile="$AccessPointWorkSpacePath/OriginalFiles/hostapdOriginal"
    
    # Activate the hostapd_log file generating new file and saving old file
    move_file "$HostapdDefaultConfigFile" "$HostapdDefaultConfigCopyFile" set_

    readonly HostapdLogFile="$AccessPointWorkSpacePath/hostapd.log"
    local -r hostapdDefaultConfigLineRegex="^#DAEMON_OPTS=\".*\"$|^DAEMON_OPTS=\".*\"$"
    local -r hostapdDefaultConfigLine="DAEMON_OPTS=\"-d -t -f $HostapdLogFile\""
    
    sed -r "s/$hostapdDefaultConfigLineRegex/${hostapdDefaultConfigLine//\//\\\/}/g" \
      "$HostapdDefaultConfigCopyFile" > "$HostapdDefaultConfigFile"

    # If Hostapd default file is empty, abort.
    if [ ! -s "$HostapdDefaultConfigFile" ]; then
        echo -e "$AccessPointDefaultError the log file isn't loaded in $HostapdDefaultConfigFile"
        return 1
    fi
    
    readonly HostapdConfigCopyFile="$AccessPointWorkSpacePath/OriginalFiles/hostapdOriginal.conf"
    
    # Assure the config file is previously loaded in the daemon
    local -r hostapdDaemon="/etc/init.d/hostapd"
    if ! cat "$hostapdDaemon" | grep -Eq "^DAEMON_CONF=$HostapdConfigFile$"; then
        echo -e "$AccessPointDefaultError the config file isn't loaded in $hostapdDaemon"
        echo "Please make sure to load this line: 'DAEMON_CONF=$HostapdConfigFile' in $hostapdDaemon"
        return 2
    fi

    move_file "$HostapdConfigFile" "$HostapdConfigCopyFile" set_

    readonly SSID="Nel prro"
    local -r password="9876543210"
    local -r channel=5

    # I delete "wpa_key_mgmt=WPA­-PSK" becouse i have an error starting hostapd service.
    # Attempt uncomment it if you don't have errors with "wpa_key_mgmt=WPA­-PSK"
    local -r configuration=(
      "interface=$InterfaceAccessPoint" 
      "driver=nl80211" 
      "ssid=$SSID" 
      "channel=$channel" 
      "hw_mode=g" "auth_algs=1" 
      "wpa=2" "wpa_passphrase=$password"
      #"wpa_key_mgmt=WPA­-PSK" 
      "wpa_pairwise=TKIP CCMP"
      "rsn_pairwise=CCMP"
      "ap_max_inactivity=21600"
    )
    
    generate_config_file "$HostapdConfigFile" configuration[@]
}

unset_hostapd_config()
{
    move_file "$HostapdDefaultConfigCopyFile" "$HostapdDefaultConfigFile" unset_

    move_file "$HostapdConfigCopyFile" "$HostapdConfigFile" unset_

    rm $HostapdLogFile &> /dev/null
}

set_dhcp_config()
{
    readonly DhcpDefaultConfigCopyFile="$AccessPointWorkSpacePath/OriginalFiles/isc-dhcp-serverOriginal"
    if [ ! -f "$DhcpDefaultConfigFile" ]; then
        echo -e "$AccessPointDefaultError $DhcpDefaultConfigFile is missing"
        return 1  
    fi

    # Specify the access point interface for the dhcp server.
    local -r old_dhcp_interfacesv4="$(grep -E "^INTERFACESv4=\".*\"$" $DhcpDefaultConfigFile)"
    local -r new_dhcp_interfacesv4="$(echo "$old_dhcp_interfacesv4" | 
      sed -r "s/(^INTERFACESv4=)\".*\"$/\1\"$InterfaceAccessPoint\"/")"
    
    if [ ! "$old_dhcp_interfacesv4" -o ! "$new_dhcp_interfacesv4" ]; then
        echo -e "$AccessPointDefaultError Cannot find 'INTERFACESv4' in $DhcpDefaultConfigFile"
        return 2
    fi

    move_file "$DhcpDefaultConfigFile" "$DhcpDefaultConfigCopyFile" set_

    sed -r "s/^INTERFACESv4=\".*\"$/$new_dhcp_interfacesv4/g" $DhcpDefaultConfigCopyFile \
      > $DhcpDefaultConfigFile

    # Configure dhcp server
    readonly DhcpServerConfigCopyFile="$AccessPointWorkSpacePath/OriginalFiles/dhcpdOriginal.conf"

    move_file "$DhcpServerConfigFile" "$DhcpServerConfigCopyFile" set_

    local -r dhcp_server_configuration=(
      "option domain-name \"example.org\";"
      "option domain-name-servers ns1.example.org, ns2.example.org;"
      "" 
      "default-lease-time 600;"
      "max-lease-time 7200;"
      ""
      "ddns-update-style none;"
      ""
      "authoritative;"
      ""
      "subnet $AccessPointSubnet netmask $AccessPointNetmask"
      "{"
      "    range $AccessPointDhcpRange;"
      "    option routers $ForwardIp;"
      "    option subnet-mask $AccessPointNetmask;"
      "    option domain-name-servers $AccessPointDnsServer;"
      "}"
    )

    generate_config_file "$DhcpServerConfigFile" dhcp_server_configuration[@]
}

unset_dhcp_config()
{
    move_file "$DhcpDefaultConfigCopyFile" "$DhcpDefaultConfigFile" unset_

    move_file "$DhcpServerConfigCopyFile" "$DhcpServerConfigFile" unset_
}

restart_services()
{
    if [ "$AccessPointState" != "Ready" ]; then return 1; fi

    local -r SERVICESLine="$AmarilloOscuro[$PurpuraOscuro*$AmarilloOscuro]$TerminarColor"
    local -r SERVICESSuccessLine="$Amarillo[$Purpura-$Amarillo]$TerminarColor"
    local -r SERVICESFailedLine="$Amarillo[$Rojo-$Amarillo]$TerminarColor"

    echo -e "$SERVICESLine Restarting the services!"

    if systemctl restart NetworkManager; then
        echo -e "$SERVICESSuccessLine NetworkManager service ${Purpura}successfully$TerminarColor resumed"
    else
        echo -e "$SERVICESFailedLine Cannot restart NetworkManager service. Error (${Purpura}3$TerminarColor)"
        return 3
    fi

    if ip addr flush dev "$InterfaceAccessPoint"; then
        echo -e "$SERVICESSuccessLine Ready to reset $Purpura$InterfaceAccessPoint$TerminarColor Ip" 
    else
        echo -e "$SERVICESFailedLine Cannot delete current $Purpura$InterfaceAccessPoint$TerminarColor Ip. Error (${Purpura}2$TerminarColor)"
        return 1
    fi

    if systemctl restart networking; then 
        echo -e "$SERVICESSuccessLine Networking service ${Purpura}successfully$TerminarColor resumed"
    else
        echo -e "$SERVICESFailedLine Cannot restart networking service. Error (${Purpura}2$TerminarColor)"
        return 2
    fi

    AccessPointState="Not Ready"
}

start_hostapd_server()
{
    if ! systemctl is-enabled hostapd &> /dev/null && ! systemctl status hostapd &> /dev/null; then
        systemctl unmask hostapd &> /dev/null 
        systemctl enable hostapd &> /dev/null 
    fi

    systemctl start hostapd &> /dev/null
    xterm -title "Hostapd Server Log" $TOPLEFT -fg "#edf6f9" -bg "#03071e" -e \
      "tail -f $HostapdLogFile" &
    readonly XtermHostapdLogPID=$!
}

stop_hostapd_server()
{   
    if [ ! "$XtermHostapdLogPID" ]; then return 1; fi

    systemctl stop hostapd &> /dev/null
    systemctl disable hostapd &> /dev/null
    kill $XtermHostapdLogPID 2> /dev/null
}

start_dhcp_server()
{
    if ! systemctl is-enabled isc-dhcp-server &> /dev/null && \
      ! systemctl status isc-dhcp-server &> /dev/null; then
        if ! systemctl enable isc-dhcp-server &> /dev/null; then return 1; fi
    fi

    systemctl start isc-dhcp-server
    xterm -title "Dhcp Server Log" $TOPRIGHT -fg "#fcf6bd" -bg "#03071e" -e \
      "tail -f /var/log/syslog | grep -i \"dhcp\"" &
    readonly XtermDhcpLogPID=$!
}

stop_dhcp_server()
{
    if [ ! "$XtermDhcpLogPID" ]; then return 1; fi

    systemctl stop isc-dhcp-server &> /dev/null
    systemctl disable isc-dhcp-server &> /dev/null
    kill $XtermDhcpLogPID 2> /dev/null
}

restore_original_files()
{
    if [ "$AccessPointState" != "Ready" ]; then return 1; fi

    local -r RESTORELine="$GrisOscuro[$CyanOscuro*$GrisOscuro]$TerminarColor"

    echo -e "$RESTORELine Restoring original files!"
    
    unset_interfaces_config
    unset_hostapd_config
    unset_dhcp_config
    unset_NetworkManager_config
}

stop_servers()
{
    if [ "$AccessPointState" != "Running" ]; then return 1; fi
    
    local -r SERVERSLine="$AzulOscuro[$AmarilloOscuro*$AzulOscuro]$TerminarColor"
    local -r SERVERSSuccessLine="$Azul[$Amarillo-$Azul]$TerminarColor"
    local -r SERVERSFailedLine="$Azul[$Rojo-$Azul]$TerminarColor"

    echo -e "$SERVERSLine Stopping all servers!" 

    if stop_hostapd_server; then
        echo -e "$SERVERSSuccessLine Stop hostapd server ${AmarilloOscuro}Successfully$TerminarColor"
    fi

    if stop_dhcp_server; then
        echo -e "$SERVERSSuccessLine Stop dhcp server ${AmarilloOscuro}Successfully$TerminarColor"
    fi

    AccessPointState="Ready"
}

set_access_point_config()
{
    if check_interfaces_integrity; then 
        get_network_info
        set_interfaces_config
        set_NetworkManager_config
    else
        return 1;
    fi

    if ! set_hostapd_config; then 
        unset_hostapd_config
        return 2
    fi

    if ! set_dhcp_config; then 
        unset_dhcp_config
        return 3
    fi
}

access_point_daemon()
{
    access_point_running_spinner()
    {
        if [ "$AccessPointState" != "Running" ]; then return 1; fi

        local -r charSequence="-+|*/\\"
        while true;
        do
        	for (( i=0; i<${#charSequence}; i++))
        	do
                sleep 0.6
                #printf "\b$RojoOscuro%s$VerdeOscuro%s$RojoOscuro%s$TerminarColor" "[ " "${charSequence:$i:1}" " ]"
        	    #printf "\b$RojoOscuro[ $VerdeOscuro${charSequence:i:1} $RojoOscuro]"
                echo -ne "\r\t\t$RojoOscuro[ $VerdeOscuro${charSequence:i:1} $RojoOscuro]$TerminarColor"
            done 
        done
    }

    trap 'exit_script 0' SIGINT SIGHUP

    start_hostapd_server

    start_dhcp_server

    echo -e "\t$AccessPointLine Access Point '$SSID' is ${Verde}running$TerminarColor $AccessPointLine"
    echo -e "\tPress [Ctrl + c] to shutdown the access point"
    access_point_running_spinner &
    local -r spinnerPID=$!
    
    # Assure all servers and config are working
    while :
    do
        local AccessPointIpProved="$(ifconfig "$InterfaceAccessPoint" | grep -E "$IpRegex" | awk '{print $2}')"

        if [ "$AccessPointIpProved" != "$AccessPointIp" ]; then
            echo -e "$AccessPointDefaultError The ip address for interface ($Verde$InterfaceAccessPoint$TerminarColor) isn't checked"
            echo -e "You can checked it:\nRunning command: 'ifconfig $Verde$InterfaceAccessPoint$TerminarColor'..."
            ifconfig $InterfaceAccessPoint
            break
        fi

        if ! systemctl status hostapd &> /dev/null; then
            echo -e "$AccessPointDefaultError Failed to start hostapd server, Exiting"
            break
        fi

        if ! systemctl status isc-dhcp-server &> /dev/null; then
            echo -e "$AccessPointDefaultError Failed to start dhcp server, Exiting..."
            break
        fi
        sleep 8
    done

    # Stop spinner
    kill $spinnerPID 2> /dev/null
    stop_servers
}

exit_script()
{
    stop_servers

    restore_original_files

    restart_services

    echo -e "\n$AccessPointLine Exiting with code ($RojoOscuro$1$TerminarColor)"

    exit $1
}

access_point_main()
{
    readonly AccessPointLine="$RojoOscuro[$VerdeOscuro*$RojoOscuro]$TerminarColor"
    readonly AccessPointDefaultError="${RojoOscuro}Error:$TerminarColor"
    
    set_resolution

    if set_access_point_config; then 
        AccessPointState="Ready"
    else
        return 1
    fi

    # Attempt restarting services before run access point
    if ! restart_services; then 
        echo -e "Failed to restarting the services, Exiting...\n"
        return 2
    fi

    AccessPointState="Running"
    access_point_daemon $$ &
    readonly AccessPointDaemonPID=$!
    
    while :
    do
        if ! ps -a | grep "$AccessPointDaemonPID" &> /dev/null; then
            break
        fi
        sleep 5
    done

    AccessPointState="Ready"
    return 3
}

access_point_handle_exit()
{
    wait $AccessPointDaemonPID
    echo -e "$AccessPointLine Thanks for using the Access Point script :)"
    echo -e "$AccessPointLine Give me a star in https://github.com/AgileSoul/LinuxAccessPoint"
    exit 0
}

trap access_point_handle_exit SIGINT
access_point_main
exit_script $? 
