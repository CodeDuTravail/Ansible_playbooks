#!/bin/bash
#
# /home/admin/scripts/firewall_set_n_check.sh
# Purpose: Monitor open ports and configure firewalld rules accordingly (RHEL/CentOS)
# Optimized version with better error handling and crontab management
#
# Crontab entry: 0 1 * * * /home/admin/scripts/firewall_set_n_check_rhel.sh
#
# -------------------------------------------------------------------------------

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly DATE=$(date +%Y_%m_%d)
readonly DEST_MAIL="YOUR_MAIL@DOMAIN.COM"
readonly FIREWALL_CONF_PATH="/home/admin/conf_backup/ports_conf"
readonly FIREWALL_CONF_FILE="$FIREWALL_CONF_PATH/firewall_ports.conf"
readonly FIREWALL_CONF_CHECK="$FIREWALL_CONF_PATH/firewall_ports.check"
readonly FIREWALL_CONF_DIFF="$FIREWALL_CONF_PATH/firewall_ports.log"
readonly FIREWALL_LAST_LOG="$FIREWALL_CONF_PATH/firewall_ports_last.log"
readonly CRON_COMMENT="# FIREWALL PORTS CONF CHECK"
readonly CRON_JOB="0 1 * * * /home/admin/scripts/firewall_set_n_check_rhel.sh"

# Logging function
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# Error handling
error_exit() {
    log_message "ERROR: $1" >&2
    exit "${2:-1}"
}

# Check if running as root (required for firewall operations)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root for firewall operations"
    fi
}

# Detect firewall system
detect_firewall_system() {
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        echo "firewalld"
    elif command -v ufw >/dev/null 2>&1; then
        echo "ufw"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "none"
    fi
}

# Get listening ports
get_listening_ports() {
    # Use ss (modern replacement for netstat) if available, fallback to netstat
    if command -v ss >/dev/null 2>&1; then
        ss -tlnH | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un
    else
        netstat -tlnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -un
    fi
}

# Create directory if it doesn't exist
ensure_directory() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        log_message "Creating directory: $dir"
        mkdir -p "$dir" || error_exit "Failed to create directory: $dir"
        chmod 755 "$dir"
    fi
}

# Add crontab entry safely (prevents duplicates)
add_crontab_entry() {
    local temp_cron
    temp_cron=$(mktemp)
    
    # Get current crontab, ignore error if no crontab exists
    crontab -l 2>/dev/null > "$temp_cron" || true
    
    # Check if our job already exists
    if ! grep -Fq "$CRON_JOB" "$temp_cron"; then
        log_message "Adding crontab entry"
        {
            echo "$CRON_COMMENT"
            echo "$CRON_JOB"
        } >> "$temp_cron"
        
        crontab "$temp_cron" || error_exit "Failed to update crontab"
        log_message "Crontab entry added successfully"
    else
        log_message "Crontab entry already exists, skipping"
    fi
    
    rm -f "$temp_cron"
}

# Configure firewall rules for ports
configure_firewall_rules() {
    local firewall_type="$1"
    shift
    local ports=("$@")
    
    log_message "Configuring $firewall_type rules for ${#ports[@]} ports"
    
    case "$firewall_type" in
        "firewalld")
            for port in "${ports[@]}"; do
                if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -gt 0 ]] && [[ "$port" -lt 65536 ]]; then
                    log_message "Adding firewalld rule: allow $port/tcp"
                    if ! firewall-cmd --permanent --add-port="$port/tcp" >/dev/null 2>&1; then
                        log_message "WARNING: Failed to add firewalld rule for port $port"
                    fi
                else
                    log_message "WARNING: Invalid port number: $port"
                fi
            done
            # Reload firewalld to apply changes
            firewall-cmd --reload >/dev/null 2>&1 || log_message "WARNING: Failed to reload firewalld"
            ;;
        "ufw")
            for port in "${ports[@]}"; do
                if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -gt 0 ]] && [[ "$port" -lt 65536 ]]; then
                    log_message "Adding UFW rule: allow $port"
                    if ! ufw allow "$port" >/dev/null 2>&1; then
                        log_message "WARNING: Failed to add UFW rule for port $port"
                    fi
                else
                    log_message "WARNING: Invalid port number: $port"
                fi
            done
            ;;
        "iptables")
            log_message "WARNING: iptables detected but automatic rule configuration not implemented"
            log_message "Please manually configure iptables rules for ports: ${ports[*]}"
            ;;
        "none")
            log_message "WARNING: No firewall system detected"
            ;;
    esac
}

# Send email notification
send_notification() {
    local subject="$1"
    local body="$2"
    
    # Try different mail systems
    if command -v msmtp >/dev/null 2>&1; then
        {
            printf "Subject: %s - %s\n\n" "$(uname -n)" "$subject"
            printf "Port monitoring report from %s\n\n" "$(uname -n)"
            printf "Generated on: %s\n\n" "$(date)"
            printf "%s\n" "$body"
        } | msmtp -a default "$DEST_MAIL" 2>/dev/null || log_message "WARNING: Failed to send email via msmtp"
    elif command -v mail >/dev/null 2>&1; then
        {
            printf "Port monitoring report from %s\n\n" "$(uname -n)"
            printf "Generated on: %s\n\n" "$(date)"
            printf "%s\n" "$body"
        } | mail -s "$(uname -n) - $subject" "$DEST_MAIL" 2>/dev/null || log_message "WARNING: Failed to send email via mail"
    else
        log_message "WARNING: No mail system found, email notification skipped"
    fi
}

# Main execution
main() {
    log_message "Starting firewall port monitoring script (RHEL/CentOS)"
    
    check_root
    
    local firewall_type
    firewall_type=$(detect_firewall_system)
    log_message "Detected firewall system: $firewall_type"
    
    ensure_directory "$FIREWALL_CONF_PATH"
    
    # Get current listening ports
    local ports
    readarray -t ports < <(get_listening_ports)
    
    if [[ ${#ports[@]} -eq 0 ]]; then
        error_exit "No listening ports found"
    fi
    
    log_message "Found ${#ports[@]} listening ports"
    
    # Initialize if config file doesn't exist
    if [[ ! -f "$FIREWALL_CONF_FILE" ]]; then
        log_message "Initializing firewall configuration"
        
        {
            echo "FIREWALL PORTS"
            printf '%s\n' "${ports[@]}"
        } > "$FIREWALL_CONF_FILE"
        
        configure_firewall_rules "$firewall_type" "${ports[@]}"
        
        case "$firewall_type" in
            "firewalld")
                log_message "Firewalld status:"
                firewall-cmd --list-ports 2>/dev/null || log_message "Failed to get firewalld status"
                ;;
            "ufw")
                log_message "UFW status:"
                ufw status numbered 2>/dev/null || log_message "Failed to get UFW status"
                ;;
        esac
        
        add_crontab_entry
        
        # Send initial configuration email
        local initial_config
        initial_config=$(cat "$FIREWALL_CONF_FILE")
        local firewall_status
        
        case "$firewall_type" in
            "firewalld")
                firewall_status=$(firewall-cmd --list-ports 2>/dev/null || echo "Firewalld status unavailable")
                ;;
            "ufw")
                firewall_status=$(ufw status numbered 2>/dev/null || echo "UFW status unavailable")
                ;;
            *)
                firewall_status="Firewall status not available for $firewall_type"
                ;;
        esac
        
        local email_body
        email_body=$(cat <<EOF
Initial firewall port configuration has been set up on $(uname -n).

DETECTED LISTENING PORTS:
$initial_config

FIREWALL RULES CONFIGURED ($firewall_type):
$firewall_status

Total ports configured: ${#ports[@]}

This is an automated notification from the firewall port monitoring system.
The system will now monitor for port changes and notify you of any modifications.

Script location: $0
Configuration path: $FIREWALL_CONF_PATH
EOF
)
        
        send_notification "Initial Firewall Configuration Complete" "$email_body"
        
        log_message "Initialization complete, notification sent"
        return 0
    fi
    
    # Backup previous diff if it exists
    [[ -f "$FIREWALL_CONF_DIFF" ]] && mv "$FIREWALL_CONF_DIFF" "$FIREWALL_LAST_LOG"
    
    # Create current port check file
    {
        echo "OPEN PORTS CHECK"
        printf '%s\n' "${ports[@]}"
    } > "$FIREWALL_CONF_CHECK"
    
    # Compare configurations
    log_message "Comparing port configurations"
    diff -y --width=40 "$FIREWALL_CONF_FILE" "$FIREWALL_CONF_CHECK" > "$FIREWALL_CONF_DIFF" || true
    
    # Check if we need to send notification
    if [[ -f "$FIREWALL_LAST_LOG" ]] && ! diff -q "$FIREWALL_LAST_LOG" "$FIREWALL_CONF_DIFF" >/dev/null 2>&1; then
        if grep -E '[<>|]' "$FIREWALL_CONF_DIFF" >/dev/null 2>&1; then
            log_message "Port changes detected, sending notification"
            local diff_content
            diff_content=$(cat "$FIREWALL_CONF_DIFF")
            send_notification "WARNING: Port configuration changed" "$diff_content"
        else
            log_message "No significant port changes detected"
        fi
    elif [[ ! -f "$FIREWALL_LAST_LOG" ]]; then
        log_message "First run comparison, no notification sent"
    else
        log_message "No changes since last run"
    fi
    
    log_message "Firewall port monitoring script completed"
}

# Execute main function
main "$@"