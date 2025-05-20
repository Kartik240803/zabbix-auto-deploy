#!/bin/bash

# ------------------------
# Zabbix Auto Installer with Upgrade Functionality
# Enhanced Script with Local Config File, Logging, Progress Bar, and Robust Error Handling
# ------------------------

# Log file setup
LOG_FILE="/var/log/zabbix_install.log"
mkdir -p "$(dirname "$LOG_FILE")" || { echo "❌ Failed to create log directory."; exit 1; }
touch "$LOG_FILE" || { echo "❌ Failed to create log file."; exit 1; }
exec 3>&1 1>>"$LOG_FILE" 2>&1

# Configuration file in the script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/zabbix_server_config.conf"

# Progress bar variables
TOTAL_STEPS=5  # Adjusted for upgrade: Backup, Repo Update, Upgrade, Restart, Verify
CURRENT_STEP=0

# Log function to write to both console and log file
log_msg() {
  local msg="$1"
  local print_to_terminal="${2:-yes}"
  local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$timestamp - $msg" >> "$LOG_FILE"
  if [[ "$print_to_terminal" == "yes" ]]; then
    echo "$timestamp - $msg" >&3
  fi
}

# Typewriter effect for console output
print_msg() {
  local msg="$1"
  for ((i = 0; i < ${#msg}; i++)); do
    echo -n "${msg:$i:1}" >&3
    sleep 0.01
  done
  echo >&3
  log_msg "$msg" yes
}

# Print centered box for console output
print_center_box() {
  local msg="$1"
  local term_width=$(tput cols)
  local box_width=$(( ${#msg} + 8 ))
  if (( box_width > term_width )); then
    box_width=$term_width
  fi
  local padding=$(( (term_width - box_width) / 2 ))

  printf "%*s" $padding "" >&3
  printf "┌%s┐\n" "$(printf '─%.0s' $(seq 1 $((box_width-2))))" >&3
  printf "%*s" $padding "" >&3
  printf "│%*s│\n" $((box_width-2)) "" >&3
  printf "%*s" $padding "" >&3
  printf "│%*s%s%*s│\n" $(( ((box_width-2-${#msg})/2) )) "" "$msg" $(( (box_width-2-${#msg}+1)/2 )) "" >&3
  printf "%*s" $padding "" >&3
  printf "│%*s│\n" $((box_width-2)) "" >&3
  printf "%*s" $padding "" >&3
  printf "└%s┘\n" "$(printf '─%.0s' $(seq 1 $((box_width-2))))" >&3
  log_msg "Centered box displayed: $msg" yes
}

# Progress bar function
print_progress() {
  local step_name="$1"
  ((CURRENT_STEP++))
  local percentage=$(( (CURRENT_STEP * 100) / TOTAL_STEPS ))
  local bar_width=50
  local filled=$(( (percentage * bar_width) / 100 ))
  local empty=$(( bar_width - filled ))

  # Build the progress bar
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+=" "; done

  # Print progress bar
  printf "\r%s: [%s] %d%%" "$step_name" "$bar" "$percentage" >&3
  echo >&3
  log_msg "Progress: $step_name - $percentage% complete" yes
}

# Detect OS and version
get_os_info() {
  if [ -e /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    OS_VERSION=$VERSION_ID
  else
    log_msg "❌ Unsupported Linux distribution." yes
    exit 1
  fi

  ARCH=$(uname -m)
  if [[ "$ARCH" == "aarch64" ]]; then
    ARCH="arm64"
  else
    ARCH="amd64"
  fi
  log_msg "Detected OS: $DISTRO $OS_VERSION ($ARCH)" yes
}

# Get Zabbix repo URL
get_zabbix_repo_url() {
  local version="$1"
  local distro="$2"
  local os_version="$3"
  local arch="$4"

  case "$distro" in
    ubuntu)
      if [[ "$arch" == "arm64" ]]; then
        echo "https://repo.zabbix.com/zabbix/${version}/ubuntu-arm64/pool/main/z/zabbix-release/zabbix-release_${version}-1+ubuntu${os_version}_all.deb"
      else
        echo "https://repo.zabbix.com/zabbix/${version}/ubuntu/pool/main/z/zabbix-release/zabbix-release_${version}-1+ubuntu${os_version}_all.deb"
      fi
      ;;
    sles)
      echo "https://repo.zabbix.com/zabbix/${version}/sles/${os_version}/${arch}/zabbix-release-${version}-1.sles${os_version}.noarch.rpm"
      ;;
    centos)
      echo "https://repo.zabbix.com/zabbix/${version}/rhel/${os_version}/${arch}/zabbix-release-${version}-1.el${os_version}.noarch.rpm"
      ;;
    *)
      log_msg "❌ Unsupported distro: $distro" yes
      exit 1
      ;;
  esac
}

# Backup Zabbix components
backup_zabbix() {
  local backup_dir="/opt/zabbix-backup-$(date +%Y%m%d_%H%M%S)"
  log_msg "🗄 Creating backup in $backup_dir..." yes

  mkdir -p "$backup_dir" || { log_msg "❌ Failed to create backup directory." yes; exit 1; }
  cp -r /etc/zabbix "$backup_dir/etc_zabbix" || { log_msg "❌ Failed to backup /etc/zabbix." yes; exit 1; }
  if [[ -d /etc/apache2 ]]; then
    cp -r /etc/apache2 "$backup_dir/etc_apache2" || { log_msg "❌ Failed to backup /etc/apache2." yes; exit 1; }
  fi
  if [[ -d /etc/nginx ]]; then
    cp -r /etc/nginx "$backup_dir/etc_nginx" || { log_msg "❌ Failed to backup /etc/nginx." yes; exit 1; }
  fi
  cp -r /usr/share/zabbix "$backup_dir/usr_share_zabbix" || { log_msg "❌ Failed to backup /usr/share/zabbix." yes; exit 1; }

  # Backup database
  local db="$1"
  if [[ "$db" == "mysql" ]]; then
    log_msg "🗄 Backing up MySQL database..." yes
    mysqldump -uroot zabbix > "$backup_dir/zabbix_db.sql" || { log_msg "❌ Failed to backup MySQL database." yes; exit 1; }
  elif [[ "$db" == "pgsql" ]]; then
    log_msg "🗄 Backing up PostgreSQL database..." yes
    sudo -u postgres pg_dump zabbix > "$backup_dir/zabbix_db.sql" || { log_msg "❌ Failed to backup PostgreSQL database." yes; exit 1; }
  fi

  log_msg "✅ Backup completed in $backup_dir." yes
  print_progress "Backup"
}

# Install database server
install_database() {
  local db="$1"
  log_msg "📦 Installing $db server..." yes
  case "$DISTRO" in
    ubuntu)
      if [[ "$db" == "mysql" ]]; then
        # Try mysql-server first, fallback to mariadb-server for ARM64
        log_msg "Attempting to install mysql-server..." yes
        if ! apt install -y mysql-server; then
          log_msg "⚠️ mysql-server installation failed, trying mariadb-server..." yes
          apt install -y mariadb-server || { log_msg "❌ Failed to install mariadb-server." yes; exit 1; }
        fi
        systemctl enable mysql || systemctl enable mariadb || { log_msg "❌ Failed to enable mysql/mariadb service." yes; exit 1; }
        systemctl start mysql || systemctl start mariadb || { log_msg "❌ Failed to start mysql/mariadb service." yes; exit 1; }
      elif [[ "$db" == "pgsql" ]]; then
        apt install -y postgresql postgresql-contrib || { log_msg "❌ Failed to install postgresql." yes; exit 1; }
        systemctl enable postgresql || { log_msg "❌ Failed to enable postgresql service." yes; exit 1; }
        systemctl start postgresql || { log_msg "❌ Failed to start postgresql service." yes; exit 1; }
      fi
      ;;
    sles)
      if [[ "$db" == "mysql" ]]; then
        zypper install -y mariadb mariadb-server || { log_msg "❌ Failed to install mariadb." yes; exit 1; }
        systemctl enable mariadb || { log_msg "❌ Failed to enable mariadb service." yes; exit 1; }
        systemctl start mariadb || { log_msg "❌ Failed to start mariadb service." yes; exit 1; }
      elif [[ "$db" == "pgsql" ]]; then
        zypper install -y postgresql postgresql-server || { log_msg "❌ Failed to install postgresql." yes; exit 1; }
        systemctl enable postgresql || { log_msg "❌ Failed to enable postgresql service." yes; exit 1; }
        systemctl start postgresql || { log_msg "❌ Failed to start postgresql service." yes; exit 1; }
      fi
      ;;
    centos)
      if [[ "$db" == "mysql" ]]; then
        dnf install -y mariadb-server || { log_msg "❌ Failed to install mariadb-server." yes; exit 1; }
        systemctl enable mariadb || { log_msg "❌ Failed to enable mariadb service." yes; exit 1; }
        systemctl start mariadb || { log_msg "❌ Failed to start mariadb service." yes; exit 1; }
      elif [[ "$db" == "pgsql" ]]; then
        dnf install -y postgresql-server || { log_msg "❌ Failed to install postgresql-server." yes; exit 1; }
        postgresql-setup --initdb || { log_msg "❌ Failed to initialize postgresql database." yes; exit 1; }
        systemctl enable postgresql || { log_msg "❌ Failed to enable postgresql service." yes; exit 1; }
        systemctl start postgresql || { log_msg "❌ Failed to start postgresql service." yes; exit 1; }
      fi
      ;;
  esac
  log_msg "✅ $db server installed and started." yes
  print_progress "Database Installation"
}

# Configure database for Zabbix
configure_database() {
  local db="$1"
  local db_password="$2"
  log_msg "🛠 Configuring $db database for Zabbix..." yes

  if [[ "$db" == "mysql" ]]; then
    mysql -uroot -e "CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;" || { log_msg "❌ Failed to create database." yes; exit 1; }
    mysql -uroot -e "CREATE USER 'zabbix'@'localhost' IDENTIFIED BY '$db_password';" || { log_msg "❌ Failed to create user." yes; exit 1; }
    mysql -uroot -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';" || { log_msg "❌ Failed to grant privileges." yes; exit 1; }
    mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 1;" || { log_msg "❌ Failed to set log_bin_trust_function_creators." yes; exit 1; }

    # Import schema
    zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -uzabbix -p"$db_password" zabbix || { log_msg "❌ Failed to import schema." yes; exit 1; }

    # Disable log_bin_trust_function_creators
    mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;" || { log_msg "❌ Failed to disable log_bin_trust_function_creators." yes; exit 1; }
  elif [[ "$db" == "pgsql" ]]; then
    sudo -u postgres psql -c "CREATE DATABASE zabbix;" || { log_msg "❌ Failed to create database." yes; exit 1; }
    sudo -u postgres psql -c "CREATE USER zabbix WITH PASSWORD '$db_password';" || { log_msg "❌ Failed to create user." yes; exit 1; }
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE zabbix TO zabbix;" || { log_msg "❌ Failed to grant privileges." yes; exit 1; }

    # Import schema
    zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | sudo -u zabbix psql zabbix || { log_msg "❌ Failed to import schema." yes; exit 1; }
  fi
  log_msg "✅ $db database configured." yes
  print_progress "Database Configuration"
}

# Configure Zabbix server
configure_zabbix_server() {
  local db="$1"
  local db_password="$2"
  log_msg "🛠 Configuring Zabbix server database settings..." yes
  local conf_file="/etc/zabbix/zabbix_server.conf"

  # Create configuration file if it doesn't exist
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_msg "Creating default configuration file: $CONFIG_FILE" yes
    cat > "$CONFIG_FILE" << EOF
DBHost=localhost
DBName=zabbix
DBUser=zabbix
DBPassword=$db_password
EOF
  fi

  # Backup the original zabbix_server.conf
  cp "$conf_file" "$conf_file.bak" || { log_msg "❌ Failed to backup $conf_file." yes; exit 1; }

  # Read and apply configuration from CONFIG_FILE
  while IFS='=' read -r key value; do
    # Skip empty lines or comments
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    key=$(echo "$key" | tr -d '[:space:]')
    value=$(echo "$value" | tr -d '[:space:]')
    log_msg "Applying configuration: $key=$value" yes

    # Remove any existing line with the key (commented or uncommented) and append the new setting
    sed -i "/^[[:space:]]*#*${key}=/d" "$conf_file" || { log_msg "❌ Failed to remove existing $key line." yes; exit 1; }
    echo "${key}=${value}" >> "$conf_file" || { log_msg "❌ Failed to append $key=$value." yes; exit 1; }
  done < "$CONFIG_FILE"

  log_msg "✅ Zabbix server configuration updated in $conf_file." yes
  print_progress "Server Configuration"
}

# Install Zabbix
install_zabbix() {
  local version="$1"
  local db="$2"
  local webserver="$3"
  local url=$(get_zabbix_repo_url "$version" "$DISTRO" "$OS_VERSION" "$ARCH")

  log_msg "🌐 Installing Zabbix $version for $DISTRO $OS_VERSION with $db and $webserver..." yes

  case "$DISTRO" in
    ubuntu)
      log_msg "Downloading Zabbix repository: $url" yes
      wget -q "$url" -O /tmp/zabbix-release.deb || { log_msg "❌ Failed to download Zabbix repo: $url" yes; exit 1; }
      dpkg -i /tmp/zabbix-release.deb || { log_msg "❌ Failed to install Zabbix repo package." yes; exit 1; }
      apt update || { log_msg "❌ Failed to update apt after adding Zabbix repo." yes; exit 1; }

      local packages=()
      if [[ "$db" == "mysql" ]]; then
        packages+=(zabbix-server-mysql)
      elif [[ "$db" == "pgsql" ]]; then
        packages+=(zabbix-server-pgsql)
      fi
      packages+=(zabbix-frontend-php)
      if [[ "$webserver" == "apache" ]]; then
        packages+=(zabbix-apache-conf)
      elif [[ "$webserver" == "nginx" ]]; then
        packages+=(zabbix-nginx-conf)
      fi
      packages+=(zabbix-sql-scripts zabbix-agent2 zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql)

      log_msg "Installing Zabbix packages: ${packages[*]}" yes
      apt install -y "${packages[@]}" || { log_msg "❌ Failed to install Zabbix packages: ${packages[*]}" yes; exit 1; }
      systemctl enable zabbix-server zabbix-agent2 || { log_msg "❌ Failed to enable Zabbix services." yes; exit 1; }
      if [[ "$webserver" == "apache" ]]; then
        apt install -y apache2 || { log_msg "❌ Failed to install apache2." yes; exit 1; }
        systemctl enable apache2 || { log_msg "❌ Failed to enable apache2 service." yes; exit 1; }
        systemctl restart zabbix-server zabbix-agent2 apache2 || { log_msg "❌ Failed to restart services." yes; exit 1; }
      elif [[ "$webserver" == "nginx" ]]; then
        apt install -y nginx php8.1-fpm || { log_msg "❌ Failed to install nginx or php8.1-fpm." yes; exit 1; }
        systemctl enable nginx php8.1-fpm || { log_msg "❌ Failed to enable nginx or php8.1-fpm services." yes; exit 1; }
        systemctl restart zabbix-server zabbix-agent2 nginx php8.1-fpm || { log_msg "❌ Failed to restart services." yes; exit 1; }
      fi
      ;;
    sles)
      log_msg "Downloading Zabbix repository: $url" yes
      rpm -Uvh --nosignature "$url" || { log_msg "❌ Failed to download Zabbix repo: $url" yes; exit 1; }
      zypper --gpg-auto-import-keys refresh 'Zabbix Official Repository' || { log_msg "❌ Failed to refresh Zabbix repo." yes; exit 1; }

      local packages=()
      if [[ "$db" == "mysql" ]]; then
        packages+=(zabbix-server-mysql)
      elif [[ "$db" == "pgsql" ]]; then
        packages+=(zabbix-server-pgsql)
      fi
      packages+=(zabbix-web-mysql)
      if [[ "$webserver" == "apache" ]]; then
        packages+=(zabbix-apache-conf-php8)
      elif [[ "$webserver" == "nginx" ]]; then
        packages+=(zabbix-nginx-conf)
      fi
      packages+=(zabbix-sql-scripts zabbix-agent2 zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql)

      log_msg "Installing Zabbix packages: ${packages[*]}" yes
      zypper install -y "${packages[@]}" || { log_msg "❌ Failed to install Zabbix packages: ${packages[*]}" yes; exit 1; }
      systemctl enable zabbix-server zabbix-agent2 || { log_msg "❌ Failed to enable Zabbix services." yes; exit 1; }
      if [[ "$webserver" == "apache" ]]; then
        systemctl enable apache2 || { log_msg "❌ Failed to enable apache2 service." yes; exit 1; }
        systemctl restart zabbix-server zabbix-agent2 apache2 || { log_msg "❌ Failed to restart services." yes; exit 1; }
      elif [[ "$webserver" == "nginx" ]]; then
        systemctl enable nginx php-fpm || { log_msg "❌ Failed to enable nginx or php-fpm services." yes; exit 1; }
        systemctl restart zabbix-server zabbix-agent2 nginx php-fpm || { log_msg "❌ Failed to restart services." yes; exit 1; }
      fi
      ;;
    centos)
      log_msg "Downloading Zabbix repository: $url" yes
      rpm -Uvh "$url" || { log_msg "❌ Failed to download Zabbix repo: $url" yes; exit 1; }
      dnf clean all || { log_msg "❌ Failed to clean dnf cache." yes; exit 1; }
      if [[ -f /etc/yum.repos.d/epel.repo ]]; then
        sed -i '/\[epel\]/a excludepkgs=zabbix*' /etc/yum.repos.d/epel.repo || { log_msg "❌ Failed to modify epel repo." yes; exit 1; }
      fi

      local packages=()
      if [[ "$db" == "mysql" ]]; then
        packages+=(zabbix-server-mysql)
      elif [[ "$db" == "pgsql" ]]; then
        packages+=(zabbix-server-pgsql)
      fi
      packages+=(zabbix-web-mysql zabbix-sql-scripts zabbix-selinux-policy zabbix-agent2 zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql)
      if [[ "$webserver" == "apache" ]]; then
        packages+=(zabbix-apache-conf)
      elif [[ "$webserver" == "nginx" ]]; then
        packages+=(zabbix-nginx-conf)
      fi

      log_msg "Installing Zabbix packages: ${packages[*]}" yes
      dnf install -y "${packages[@]}" || { log_msg "❌ Failed to install Zabbix packages: ${packages[*]}" yes; exit 1; }
      systemctl enable zabbix-server zabbix-agent2 || { log_msg "❌ Failed to enable Zabbix services." yes; exit 1; }
      if [[ "$webserver" == "apache" ]]; then
        systemctl enable httpd php-fpm || { log_msg "❌ Failed to enable httpd or php-fpm services." yes; exit 1; }
        systemctl restart zabbix-server zabbix-agent2 httpd php-fpm || { log_msg "❌ Failed to restart services." yes; exit 1; }
      elif [[ "$webserver" == "nginx" ]]; then
        systemctl enable nginx php-fpm || { log_msg "❌ Failed to enable nginx or php-fpm services." yes; exit 1; }
        systemctl restart zabbix-server zabbix-agent2 nginx php-fpm || { log_msg "❌ Failed to restart services." yes; exit 1; }
      fi
      ;;
  esac
  log_msg "✅ Zabbix $version installed successfully." yes
  print_progress "Zabbix Installation"
}

# Upgrade Zabbix
upgrade_zabbix() {
  local version="$1"
  local db="$2"
  local webserver="$3"
  local url=$(get_zabbix_repo_url "$version" "$DISTRO" "$OS_VERSION" "$ARCH")

  log_msg "🔄 Upgrading Zabbix to version $version for $DISTRO $OS_VERSION with $db and $webserver..." yes

  # Stop Zabbix services
  log_msg "🛑 Stopping Zabbix services..." yes
  systemctl stop zabbix-server zabbix-agent2 || { log_msg "❌ Failed to stop Zabbix services." yes; exit 1; }
  if [[ "$webserver" == "apache" ]]; then
    systemctl stop apache2 || { log_msg "❌ Failed to stop apache2." yes; exit 1; }
  elif [[ "$webserver" == "nginx" ]]; then
    systemctl stop nginx php8.1-fpm || { log_msg "❌ Failed to stop nginx or php8.1-fpm." yes; exit 1; }
  fi

  # Backup Zabbix components
  backup_zabbix "$db"

  # Update repository
  log_msg "🌐 Updating Zabbix repository to version $version: $url" yes
  wget -q "$url" -O /tmp/zabbix-release.deb || { log_msg "❌ Failed to download Zabbix repo: $url" yes; exit 1; }
  dpkg -i /tmp/zabbix-release.deb || { log_msg "❌ Failed to install Zabbix repo package." yes; exit 1; }
  apt update || { log_msg "❌ Failed to update apt after adding Zabbix repo." yes; exit 1; }
  print_progress "Repository Update"

  # Upgrade Zabbix packages
  local packages=()
  if [[ "$db" == "mysql" ]]; then
    packages+=(zabbix-server-mysql)
  elif [[ "$db" == "pgsql" ]]; then
    packages+=(zabbix-server-pgsql)
  fi
  packages+=(zabbix-frontend-php zabbix-agent2 zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql)
  if [[ "$webserver" == "apache" ]]; then
    packages+=(zabbix-apache-conf)
  elif [[ "$webserver" == "nginx" ]]; then
    packages+=(zabbix-nginx-conf)
  fi

  log_msg "📦 Upgrading Zabbix packages: ${packages[*]}" yes
  # Use --only-upgrade to ensure only installed packages are updated
  DEBIAN_FRONTEND=noninteractive apt install -y --only-upgrade "${packages[@]}" || { log_msg "❌ Failed to upgrade Zabbix packages: ${packages[*]}" yes; exit 1; }
  print_progress "Zabbix Upgrade"

  # Restart services
  log_msg "🔄 Restarting services..." yes
  systemctl restart zabbix-server zabbix-agent2 || { log_msg "❌ Failed to restart Zabbix services." yes; exit 1; }
  if [[ "$webserver" == "apache" ]]; then
    systemctl restart apache2 || { log_msg "❌ Failed to restart apache2." yes; exit 1; }
  elif [[ "$webserver" == "nginx" ]]; then
    systemctl restart nginx php8.1-fpm || { log_msg "❌ Failed to restart nginx or php8.1-fpm." yes; exit 1; }
  fi
  print_progress "Service Restart"

  # Verify upgrade
  log_msg "🔍 Verifying Zabbix version..." yes
  local installed_version=$(zabbix_server -V | grep -oP 'Zabbix \K[0-9]+\.[0-9]+')
  if [[ "$installed_version" == "$version" ]]; then
    log_msg "✅ Zabbix successfully upgraded to version $version." yes
  else
    log_msg "❌ Upgrade verification failed. Expected version $version, found $installed_version." yes
    exit 1
  fi
  print_progress "Version Verification"
}

# Uninstall Zabbix
uninstall_zabbix() {
  log_msg "🧹 Stopping and disabling Zabbix services..." yes
  systemctl stop zabbix-server zabbix-agent zabbix-agent2 apache2 nginx httpd php-fpm php8.1-fpm || true
  systemctl disable zabbix-server zabbix-agent zabbix-agent2 apache2 nginx httpd php-fpm php8.1-fpm || true

  log_msg "📦 Detecting installed Zabbix packages..." yes
  case "$DISTRO" in
    ubuntu)
      ZBX_PACKAGES=$(dpkg -l | awk '/^ii/ && $2 ~ /^zabbix/ { print $2 }')
      if [[ -n "$ZBX_PACKAGES" ]]; then
        log_msg "🧹 Removing the following Zabbix packages: $ZBX_PACKAGES" yes
        apt remove --purge -y $ZBX_PACKAGES || log_msg "⚠️ Failed to remove Zabbix packages." yes
      else
        log_msg "ℹ️ No Zabbix packages found to remove." yes
      fi
      apt autoremove -y || log_msg "⚠️ Failed to autoremove packages." yes
      rm -f /etc/apt/sources.list.d/zabbix.list
      apt update || log_msg "⚠️ Failed to update apt after cleanup." yes
      ;;
    sles)
      ZBX_PACKAGES=$(rpm -qa | grep ^zabbix)
      if [[ -n "$ZBX_PACKAGES" ]]; then
        log_msg "🧹 Removing the following Zabbix packages: $ZBX_PACKAGES" yes
        zypper remove -y $ZBX_PACKAGES || log_msg "⚠️ Failed to remove Zabbix packages." yes
      else
        log_msg "ℹ️ No Zabbix packages found to remove." yes
      fi
      zypper clean || log_msg "⚠️ Failed to clean zypper cache." yes
      ;;
    centos)
      ZBX_PACKAGES=$(rpm -qa | grep ^zabbix)
      if [[ -n "$ZBX_PACKAGES" ]]; then
        log_msg "🧹 Removing the following Zabbix packages: $ZBX_PACKAGES" yes
        dnf remove -y $ZBX_PACKAGES || log_msg "⚠️ Failed to remove Zabbix packages." yes
      else
        log_msg "ℹ️ No Zabbix packages found to remove." yes
      fi
      dnf clean all || log_msg "⚠️ Failed to clean dnf cache." yes
      ;;
  esac

  # Prompt to remove database and user
  log_msg "🗑️ Database cleanup" yes
  echo "⚠️ Do you want to remove the Zabbix database? (y/n): " >&3
  read -r remove_db >&3
  log_msg "User response for database cleanup: $remove_db" yes
  if [[ "$remove_db" == "y" ]]; then
    echo "⚠️ Is the database MySQL or PostgreSQL? (mysql/pgsql): " >&3
    read -r db_type >&3
    log_msg "User specified database type: $db_type" yes
    if [[ "$db_type" == "mysql" ]]; then
      log_msg "🧹 Dropping MySQL database and user..." yes
      mysql -uroot -e "DROP DATABASE IF EXISTS zabbix;" || log_msg "⚠️ Failed to drop database." yes
      mysql -uroot -e "DROP USER IF EXISTS 'zabbix'@'localhost';" || log_msg "⚠️ Failed to drop user." yes
    elif [[ "$db_type" == "pgsql" ]]; then
      log_msg "🧹 Dropping PostgreSQL database and user..." yes
      sudo -u postgres psql -c "DROP DATABASE IF EXISTS zabbix;" || log_msg "⚠️ Failed to drop database." yes
      sudo -u postgres psql -c "DROP USER IF EXISTS zabbix;" || log_msg "⚠️ Failed to drop user." yes
    else
      log_msg "❌ Invalid database type. Skipping database cleanup." yes
    fi
  else
    log_msg "ℹ️ Zabbix database and user will be retained." yes
  fi

  log_msg "✅ Zabbix uninstalled." yes
}

# Main Entry
MODE=""
ZBX_VERSION=""
DB=""
WEBSERVER=""
ACTION=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --default)
      MODE="default"
      ;;
    --manual)
      MODE="manual"
      ;;
    --version)
      ZBX_VERSION="$2"
      shift
      ;;
    --db)
      DB="$2"
      shift
      ;;
    --webserver)
      WEBSERVER="$2"
      shift
      ;;
    --install)
      ACTION="install"
      ;;
    --upgrade)
      ACTION="upgrade"
      ;;
    --uninstall)
      ACTION="uninstall"
      ;;
    *)
      log_msg "❌ Unknown option: $1" yes
      exit 1
      ;;
  esac
  shift
done

# Validate inputs
if [[ -z "$ACTION" ]]; then
  log_msg "Usage: $0 [--install|--upgrade|--uninstall] [--default|--manual] --version <zabbix_version> --db <mysql|pgsql> --webserver <apache|nginx>" yes
  exit 1
fi

if [[ "$ACTION" != "uninstall" ]]; then
  if [[ -z "$ZBX_VERSION" || -z "$DB" || -z "$WEBSERVER" ]]; then
    log_msg "Usage: $0 [--install|--upgrade] [--default|--manual] --version <zabbix_version> --db <mysql|pgsql> --webserver <apache|nginx]" yes
    exit 1
  fi

  if [[ ! "$ZBX_VERSION" =~ ^(6\.0|6\.4|7\.0)$ ]]; then
    log_msg "❌ Invalid Zabbix version: $ZBX_VERSION. Allowed versions are: 6.0, 6.4, 7.0." yes
    exit 1
  fi

  if [[ "$DB" != "mysql" && "$DB" != "pgsql" ]]; then
    log_msg "❌ Invalid database: $DB. Allowed databases are: mysql, pgsql." yes
    exit 1
  fi

  if [[ "$WEBSERVER" != "apache" && "$WEBSERVER" != "nginx" ]]; then
    log_msg "❌ Invalid webserver: $WEBSERVER. Allowed webservers are: apache, nginx." yes
    exit 1
  fi
fi

# Prompt for database password in manual mode for install
if [[ "$ACTION" == "install" && "$MODE" == "manual" && -z "$DB_PASSWORD" ]]; then
  echo "Enter database password: " >&3
  read -s DB_PASSWORD >&3
  echo >&3
  log_msg "Database password provided." yes
  if [[ -z "$DB_PASSWORD" ]]; then
    log_msg "❌ Database password cannot be empty." yes
    exit 1
  fi
elif [[ "$ACTION" == "install" && "$MODE" == "default" ]]; then
  DB_PASSWORD="zabbix_password"
  log_msg "Using default database password." yes
fi

# Detect OS
get_os_info

# Execute action
case "$ACTION" in
  install)
    # Confirm installation
    print_center_box "Zabbix $ZBX_VERSION Installation"
    print_msg "ℹ️ Installing Zabbix $ZBX_VERSION with $DB and $WEBSERVER on $DISTRO $OS_VERSION ($ARCH)"
    echo "⚠️ Continue? (y/n): " >&3
    read -r confirm >&3
    log_msg "User confirmation: $confirm" yes
    if [[ "$confirm" != "y" ]]; then
      log_msg "❌ Aborted by user." yes
      exit 1
    fi

    # Install prerequisites
    case "$DISTRO" in
      ubuntu)
        log_msg "Updating apt package index..." yes
        apt update || { log_msg "❌ Failed to update apt." yes; exit 1; }
        log_msg "Installing prerequisites (wget, curl)..." yes
        apt install -y wget curl || { log_msg "❌ Failed to install prerequisites." yes; exit 1; }
        ;;
      sles)
        log_msg "Installing prerequisites (wget, curl)..." yes
        zypper install -y wget curl || { log_msg "❌ Failed to install prerequisites." yes; exit 1; }
        ;;
      centos)
        log_msg "Installing prerequisites (wget, curl)..." yes
        dnf install -y wget curl || { log_msg "❌ Failed to install prerequisites." yes; exit 1; }
        ;;
      *)
        log_msg "❌ Distro $DISTRO is not supported." yes
        exit 1
        ;;
    esac
    log_msg "✅ Prerequisites installed." yes
    print_progress "Prerequisites Installation"

    # Install database
    install_database "$DB"

    # Install Zabbix
    install_zabbix "$ZBX_VERSION" "$DB" "$WEBSERVER"

    # Configure database
    configure_database "$DB" "$DB_PASSWORD"

    # Configure Zabbix server
    configure_zabbix_server "$DB" "$DB_PASSWORD"

    print_center_box "Installation Complete"
    print_msg "✅ Zabbix $ZBX_VERSION is installed and configured."
    print_msg "🌐 Access the Zabbix frontend at http://<server_ip>/zabbix"
    print_msg "👤 Default login: Admin / zabbix"
    print_msg "📜 Log file: $LOG_FILE"
    print_msg "⚙️ Configuration file: $CONFIG_FILE"
    ;;
  upgrade)
    # Confirm upgrade
    print_center_box "Zabbix $ZBX_VERSION Upgrade"
    print_msg "ℹ️ Upgrading Zabbix to $ZBX_VERSION with $DB and $WEBSERVER on $DISTRO $OS_VERSION ($ARCH)"
    echo "⚠️ Continue? (y/n): " >&3
    read -r confirm >&3
    log_msg "User confirmation: $confirm" yes
    if [[ "$confirm" != "y" ]]; then
      log_msg "❌ Aborted by user." yes
      exit 1
    fi

    # Perform upgrade
    upgrade_zabbix "$ZBX_VERSION" "$DB" "$WEBSERVER"

    print_center_box "Upgrade Complete"
    print_msg "✅ Zabbix upgraded to $ZBX_VERSION."
    print_msg "🌐 Access the Zabbix frontend at http://<server_ip>/zabbix"
    print_msg "📜 Log file: $LOG_FILE"
    print_msg "⚠️ Clear browser cache if the web interface has issues."
    ;;
  uninstall)
    uninstall_zabbix
    print_center_box "Uninstallation Complete"
    print_msg "✅ Zabbix has been uninstalled."
    print_msg "📜 Log file: $LOG_FILE"
    ;;
esac