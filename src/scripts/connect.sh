#!/bin/bash

## Checking if WireGuard client is configured for full tunnel
if echo "${!CONFIG}" | base64 --decode | grep "AllowedIPs" | grep -E "0.0.0.0/|::/"; then
  echo "It appears your WireGuard client is configured to route all traffic via the VPN (full tunnel)."
  echo "Full tunnel implementations are not supported in the CircleCI environment."
  echo "Please make sure to configure your WireGuard client to route specific IPs."
  echo "Failing the build."
  exit 1
fi

case "$(uname)" in
  [Ll]inux*)
    if [ -f /.dockerenv ]; then
      EXECUTOR=docker
      printf "The WireGuard orb does not support the 'docker' executor.\n"
      printf "Please use the Linux 'machine' executor instead."
      exit 1
    else
      EXECUTOR=linux
    fi
    PLATFORM=Linux
    ping_command=(ping -c1 "$WG_SRV_IP")
    check_install=(wg --version)
    ;;
  [Dd]arwin*)
    PLATFORM=macOS
    EXECUTOR=macos
    ping_command=(ping -c1 "$WG_SRV_IP")
    check_install=(wg --version)
    ;;
  msys*|MSYS*|nt|win*)
    PLATFORM=Windows
    EXECUTOR=windows
    ping_command=(ping -n 1 "$WG_SRV_IP")
    check_install=(/c/progra~1/wireguard/wg.exe --version)
    ;;
esac

install-Linux() {
  printf "Installing WireGuard for Linux\n\n"
  sudo apt-get update
  sudo apt-get install -y wireguard-tools resolvconf
  printf "\nWireGuard for %s installed\n\n" "$PLATFORM"
}

install-macOS() {
  printf "Installing WireGuard for macOS\n\n"
  HOMEBREW_NO_AUTO_UPDATE=1 brew install wireguard-tools
  sudo sed -i '' 's/\/usr\/bin\/env[[:space:]]bash/\/usr\/local\/bin\/bash/' /usr/local/Cellar/wireguard-tools/1.0.20210914/bin/wg-quick
  printf "\nWireGuard for %s installed\n\n" "$PLATFORM"
}

install-Windows() {
  printf "Installing WireGuard for Windows\n\n"
  choco install wireguard
  printf "\nWireGuard for %s installed\n" "$PLATFORM"
}

configure-Linux() {
  echo "${!CONFIG}" | sudo bash -c 'base64 --decode > /etc/wireguard/wg0.conf'
  sudo chmod 600 /tmp/wg0.conf
}

configure-macOS() {
  sudo mkdir /etc/wireguard
  echo "${!CONFIG}" |  sudo bash -c 'base64 --decode > /etc/wireguard/wg0.conf'
  sudo chmod 600 /tmp/wg0.conf
}

configure-Windows() {
  echo "${!CONFIG}" | base64 --decode > "C:\tmp\wg0.conf"
}

if "${check_install[@]}" 2>/dev/null; then
  printf "WireGuard is already installed\n"
else
  install-$PLATFORM
fi

configure-$PLATFORM
printf "\nWireGuard for %s configured\n" "$PLATFORM"

printf "\nPublic IP before VPN connection is %s\n\n" "$(curl -s http://checkip.amazonaws.com)"

connect-linux() {
  sudo wg-quick up wg0
}

connect-macos() {
cat << EOF | sudo tee /Library/LaunchDaemons/com.wireguard.wg0.plist 1>/dev/null
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.wireguard.wg0</string>
    <key>ProgramArguments</key>
    <array>
      <string>/usr/local/bin/wg-quick</string>
      <string>up</string>
      <string>wg0</string>
    </array>
  </dict>
</plist>
EOF
  
  printf "\nWireguard daemon configured\n\n"
  
  sudo launchctl load /Library/LaunchDaemons/com.wireguard.wg0.plist
  sudo launchctl start com.wireguard.wg0
  
  until sudo launchctl list | grep wireguard; do
    sleep 1
  done
}

connect-windows() {
  /c/progra~1/wireguard/wireguard.exe //installtunnelservice "C:\tmp\wg0.conf"
}

connect-"$EXECUTOR"

counter=1
  until "${ping_command[@]}" || [ "$counter" -ge $((TIMEOUT)) ]; do
    ((counter++))
    echo "Attempting to connect..."
    sleep 1;
  done

  if (! "${ping_command[@]}" > /dev/null); then
    printf "\nUnable to establish connection within the allocated time ---> Giving up.\n"
  else
    printf "\nConnected to WireGuard server\n"
    #printf "\nPublic IP is now %s\n" "$(curl -s http://checkip.amazonaws.com)"
  fi

echo "export PLATFORM=$PLATFORM" >> "$BASH_ENV"
echo "export EXECUTOR=$EXECUTOR" >> "$BASH_ENV"