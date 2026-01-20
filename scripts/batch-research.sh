#!/bin/bash
#
# Batch Research Automation Script
# Sends "Perform full research of: [company] [domain]" to Copilot Studio
# every 60 seconds, with monitoring via export-activities.sh
#

set -e

# Configuration
CSV_FILE="${1:-./companies.csv}"
INTERVAL_SECONDS="${2:-60}"
START_INDEX="${3:-1}"  # 1-based index to resume from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/batch_research_${TIMESTAMP}.log"

# Copilot Studio Config (set these for your environment)
ENV_ID="${COPILOT_ENV_ID:?Set COPILOT_ENV_ID or edit this script}"
BOT_ID="${COPILOT_BOT_GUID:?Set COPILOT_BOT_GUID or edit this script}"
COPILOT_URL="https://copilotstudio.preview.microsoft.com/environments/${ENV_ID}/bots/${BOT_ID}/canvas"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create log directory
mkdir -p "$LOG_DIR"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

log_success() {
    log "${GREEN}✓ $1${NC}"
}

log_warning() {
    log "${YELLOW}⚠ $1${NC}"
}

log_error() {
    log "${RED}✗ $1${NC}"
}

log_info() {
    log "${BLUE}ℹ $1${NC}"
}

# Check dependencies
check_dependencies() {
    if ! command -v node &> /dev/null; then
        log_error "Node.js is required but not installed."
        exit 1
    fi

    if ! npx playwright --version &> /dev/null 2>&1; then
        log_warning "Playwright not found. Installing..."
        npm install -g playwright
        npx playwright install chromium
    fi
}

# Parse CSV and get companies
parse_csv() {
    local csv_file="$1"
    local start_idx="$2"

    # Skip header line, start from specified index
    tail -n +2 "$csv_file" | tail -n +"$start_idx"
}

# Send research request via Playwright
send_research_request() {
    local company_name="$1"
    local domain="$2"
    local message="Perform full research of: ${company_name} ${domain}"

    log_info "Sending: $message"

    # Create a temporary Node.js script to send the message
    local temp_script=$(mktemp /tmp/playwright_send_XXXXXX.js)

    cat > "$temp_script" << 'PLAYWRIGHT_SCRIPT'
const { chromium } = require('playwright');

async function sendMessage(url, message) {
    const browser = await chromium.connectOverCDP('http://localhost:9222');
    const contexts = browser.contexts();

    if (contexts.length === 0) {
        console.error('No browser contexts found. Make sure Chrome is running with --remote-debugging-port=9222');
        process.exit(1);
    }

    const context = contexts[0];
    const pages = context.pages();

    // Find or navigate to Copilot Studio
    let page = pages.find(p => p.url().includes('copilotstudio'));

    if (!page) {
        page = await context.newPage();
        await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
        await page.waitForTimeout(3000);
    }

    // Wait for chat input
    const chatInput = await page.waitForSelector('[placeholder="Type your message"]', { timeout: 30000 });

    // Clear and type message
    await chatInput.fill(message);

    // Click send button
    const sendButton = await page.waitForSelector('button[aria-label="Send"], button:has-text("Send")', { timeout: 5000 });
    await sendButton.click();

    // Wait for response to start
    await page.waitForTimeout(2000);

    console.log('Message sent successfully');

    // Don't close - keep browser open
    await browser.disconnect();
}

const url = process.argv[2];
const message = process.argv[3];

sendMessage(url, message).catch(err => {
    console.error('Error:', err.message);
    process.exit(1);
});
PLAYWRIGHT_SCRIPT

    # Run the playwright script
    if node "$temp_script" "$COPILOT_URL" "$message" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Research request sent for: $company_name"
        rm -f "$temp_script"
        return 0
    else
        log_error "Failed to send request for: $company_name"
        rm -f "$temp_script"
        return 1
    fi
}

# Alternative: Use MCP Playwright server if available
send_via_mcp() {
    local company_name="$1"
    local domain="$2"
    local message="Perform full research of: ${company_name} ${domain}"

    # This would be called from Claude Code directly
    echo "MCP_SEND:$message"
}

# Run monitoring script
run_monitoring() {
    local conversation_id="$1"

    if [[ -n "$conversation_id" && -f "${SCRIPT_DIR}/export-activities.sh" ]]; then
        log_info "Running monitoring for conversation: $conversation_id"
        "${SCRIPT_DIR}/export-activities.sh" -c "$conversation_id" --analytics-only 2>&1 | tee -a "$LOG_FILE"
    fi
}

# Main batch processing loop
run_batch() {
    local csv_file="$1"
    local interval="$2"
    local start_idx="$3"

    if [[ ! -f "$csv_file" ]]; then
        log_error "CSV file not found: $csv_file"
        exit 1
    fi

    local total_companies=$(tail -n +2 "$csv_file" | wc -l | tr -d ' ')
    local current_idx=$start_idx

    log_info "=========================================="
    log_info "Batch Research Automation"
    log_info "=========================================="
    log_info "CSV File: $csv_file"
    log_info "Total Companies: $total_companies"
    log_info "Starting from: $start_idx"
    log_info "Interval: ${interval}s between requests"
    log_info "Log File: $LOG_FILE"
    log_info "=========================================="

    # Parse CSV and process each company
    while IFS=',' read -r company_name domain; do
        # Skip empty lines
        [[ -z "$company_name" ]] && continue

        # Remove quotes if present
        company_name=$(echo "$company_name" | sed 's/^"//;s/"$//')
        domain=$(echo "$domain" | sed 's/^"//;s/"$//')

        # Skip if domain is empty
        [[ -z "$domain" ]] && {
            log_warning "Skipping $company_name - no domain"
            ((current_idx++))
            continue
        }

        log_info "------------------------------------------"
        log_info "Processing [$current_idx/$total_companies]: $company_name ($domain)"
        log_info "------------------------------------------"

        # Send research request
        if send_research_request "$company_name" "$domain"; then
            # Record success
            echo "${current_idx},${company_name},${domain},SUCCESS,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${LOG_DIR}/batch_results_${TIMESTAMP}.csv"
        else
            # Record failure
            echo "${current_idx},${company_name},${domain},FAILED,$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${LOG_DIR}/batch_results_${TIMESTAMP}.csv"
        fi

        ((current_idx++))

        # Check if we've processed all companies
        if [[ $current_idx -gt $total_companies ]]; then
            log_success "All companies processed!"
            break
        fi

        # Wait before next request
        log_info "Waiting ${interval}s before next request..."
        log_info "Progress: $current_idx / $total_companies ($(( (current_idx * 100) / total_companies ))%)"

        # Countdown display
        for ((i=interval; i>0; i--)); do
            printf "\r${BLUE}Next request in: %3d seconds${NC}" "$i"
            sleep 1
        done
        echo ""

    done < <(parse_csv "$csv_file" "$start_idx")

    log_info "=========================================="
    log_success "Batch processing complete!"
    log_info "Results saved to: ${LOG_DIR}/batch_results_${TIMESTAMP}.csv"
    log_info "=========================================="
}

# Interactive mode using Claude MCP
run_interactive() {
    local csv_file="$1"
    local start_idx="$2"

    log_info "Interactive mode - will output commands for Claude MCP"

    local idx=0
    while IFS=',' read -r company_name domain; do
        ((idx++))
        [[ $idx -lt $start_idx ]] && continue
        [[ -z "$company_name" || -z "$domain" ]] && continue

        company_name=$(echo "$company_name" | sed 's/^"//;s/"$//')
        domain=$(echo "$domain" | sed 's/^"//;s/"$//')

        echo "RESEARCH_REQUEST:$idx:$company_name:$domain"

    done < <(tail -n +2 "$csv_file")
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [CSV_FILE] [INTERVAL] [START_INDEX]

Batch research automation for Copilot Studio.

Arguments:
    CSV_FILE      Path to companies CSV (default: ./companies.csv)
    INTERVAL      Seconds between requests (default: 60)
    START_INDEX   1-based index to start from (default: 1)

Options:
    -h, --help        Show this help message
    -i, --interactive Run in interactive mode (output commands for Claude MCP)
    -m, --monitor     Run monitoring only (requires conversation ID)
    -l, --list        List companies from CSV

Examples:
    $0                              # Start from beginning with defaults
    $0 companies.csv 90 10          # Start from company #10, 90s interval
    $0 -l                           # List all companies
    $0 -i                           # Interactive mode for Claude MCP

EOF
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    -i|--interactive)
        run_interactive "${2:-$CSV_FILE}" "${3:-1}"
        exit 0
        ;;
    -l|--list)
        echo "Companies in CSV:"
        tail -n +2 "${2:-$CSV_FILE}" | nl
        exit 0
        ;;
    -m|--monitor)
        run_monitoring "$2"
        exit 0
        ;;
    *)
        check_dependencies
        run_batch "$CSV_FILE" "$INTERVAL_SECONDS" "$START_INDEX"
        ;;
esac
