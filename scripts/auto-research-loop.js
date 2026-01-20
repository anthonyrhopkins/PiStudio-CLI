#!/usr/bin/env node
/**
 * Auto Research Loop for Copilot Studio
 *
 * Sends research requests every 60 seconds using Playwright MCP
 * Monitors progress via export-activities.sh
 *
 * Usage: node auto-research-loop.js [start_index] [interval_seconds]
 */

const fs = require('fs');
const path = require('path');
const { exec, spawn } = require('child_process');

// Configuration
const CSV_FILE = process.env.CSV_FILE || './companies.csv';
const START_INDEX = parseInt(process.argv[2] || '1', 10);
const INTERVAL_SECONDS = parseInt(process.argv[3] || '60', 10);
const LOG_DIR = path.join(__dirname, '..', 'logs');

// Ensure log directory exists
if (!fs.existsSync(LOG_DIR)) {
    fs.mkdirSync(LOG_DIR, { recursive: true });
}

const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
const logFile = path.join(LOG_DIR, `auto_research_${timestamp}.log`);
const resultsFile = path.join(LOG_DIR, `research_results_${timestamp}.csv`);

// Initialize results CSV
fs.writeFileSync(resultsFile, 'index,company_name,domain,status,timestamp\n');

function log(message) {
    const ts = new Date().toISOString();
    const line = `[${ts}] ${message}`;
    console.log(line);
    fs.appendFileSync(logFile, line + '\n');
}

function loadCompanies() {
    const content = fs.readFileSync(CSV_FILE, 'utf-8');
    const lines = content.split('\n').slice(1); // Skip header

    return lines
        .map((line, index) => {
            // Handle CSV with quoted fields
            const match = line.match(/^"?([^",]*)"?,(.*)$/);
            if (match) {
                return {
                    index: index + 1,
                    name: match[1].trim().replace(/^"|"$/g, ''),
                    domain: match[2].trim().replace(/^"|"$/g, '')
                };
            }
            return null;
        })
        .filter(c => c && c.name && c.domain);
}

function recordResult(company, status) {
    const line = `${company.index},"${company.name}","${company.domain}",${status},${new Date().toISOString()}\n`;
    fs.appendFileSync(resultsFile, line);
}

async function sleep(seconds) {
    return new Promise(resolve => setTimeout(resolve, seconds * 1000));
}

function runMonitoring() {
    return new Promise((resolve) => {
        const script = path.join(__dirname, 'export-activities.sh');
        exec(`"${script}" --list-bots 2>&1 | head -20`, (error, stdout) => {
            if (stdout) log(`[Monitor] ${stdout.substring(0, 200)}`);
            resolve();
        });
    });
}

// Main output for Claude MCP integration
function outputForMCP(company) {
    // This format can be parsed by Claude to send via Playwright MCP
    console.log(`\n===MCP_COMMAND===`);
    console.log(`ACTION: type_and_send`);
    console.log(`MESSAGE: Perform full research of: ${company.name} ${company.domain}`);
    console.log(`COMPANY_INDEX: ${company.index}`);
    console.log(`===END_COMMAND===\n`);
}

async function main() {
    log('========================================');
    log('Auto Research Loop Started');
    log(`CSV File: ${CSV_FILE}`);
    log(`Start Index: ${START_INDEX}`);
    log(`Interval: ${INTERVAL_SECONDS} seconds`);
    log(`Log File: ${logFile}`);
    log(`Results File: ${resultsFile}`);
    log('========================================');

    const companies = loadCompanies();
    log(`Loaded ${companies.length} companies`);

    // Filter to start from specified index
    const remaining = companies.filter(c => c.index >= START_INDEX);
    log(`Processing ${remaining.length} companies starting from index ${START_INDEX}`);

    for (const company of remaining) {
        log('------------------------------------------');
        log(`Processing [${company.index}/${companies.length}]: ${company.name} (${company.domain})`);
        log('------------------------------------------');

        // Output command for MCP
        outputForMCP(company);

        // Record as in-progress
        recordResult(company, 'SENT');

        // Wait for interval
        log(`Waiting ${INTERVAL_SECONDS} seconds before next request...`);

        // Progress indicator
        for (let i = INTERVAL_SECONDS; i > 0; i -= 10) {
            process.stdout.write(`\r  ${i} seconds remaining...`);
            await sleep(Math.min(10, i));
        }
        console.log('\n');

        // Periodic monitoring
        if (company.index % 5 === 0) {
            log('Running monitoring check...');
            await runMonitoring();
        }
    }

    log('========================================');
    log('All companies processed!');
    log(`Results saved to: ${resultsFile}`);
    log('========================================');
}

// Handle direct execution vs import
if (require.main === module) {
    main().catch(err => {
        log(`Error: ${err.message}`);
        process.exit(1);
    });
}

module.exports = { loadCompanies, outputForMCP };
