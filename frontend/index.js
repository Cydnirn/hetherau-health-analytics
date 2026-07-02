/**
 * Hetherau Health Analytics Dashboard – Frontend Script.
 * Fetches data from the API Gateway endpoint and renders the table.
 *
 * Configure API_URL to point to the deployed API Gateway endpoint.
 * For local development with static JSON, use: 'test_data.json'
 */

const API_URL =
    'https://your-api-gateway-id.execute-api.region.amazonaws.com/prod/data';

const POLL_INTERVAL_MS = 30000; // Refresh every 30 seconds

/**
 * Fetch analytics data from the API.
 */
async function fetchData() {
    const statusDot = document.getElementById('statusDot');
    const statusText = document.getElementById('statusText');
    const lastUpdated = document.getElementById('lastUpdated');
    const tableBody = document.getElementById('tableBody');

    statusDot.className = 'status-dot loading';
    statusText.textContent = 'Loading...';

    try {
        const response = await fetch(API_URL);
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        const data = await response.json();

        statusDot.className = 'status-dot connected';
        statusText.textContent = 'Connected';
        lastUpdated.textContent =
            'Last updated: ' + new Date().toLocaleTimeString();

        renderTable(data);
    } catch (error) {
        statusDot.className = 'status-dot error';
        statusText.textContent = 'Error';
        tableBody.innerHTML = `
            <tr>
                <td colspan="7" class="error-state">
                    Failed to fetch data: ${error.message}<br>
                    <small>Ensure the API Gateway endpoint is configured correctly.</small>
                </td>
            </tr>`;
        console.error('Fetch error:', error);
    }
}

/**
 * Render the data table and summary cards.
 * @param {Array} data - Array of citizen health records.
 */
function renderTable(data) {
    const tableBody = document.getElementById('tableBody');
    const totalCount = document.getElementById('totalCount');
    const healthyCount = document.getElementById('healthyCount');
    const unhealthyCount = document.getElementById('unhealthyCount');

    if (!data || data.length === 0) {
        tableBody.innerHTML = `
            <tr>
                <td colspan="7" class="empty-state">
                    No data available yet. Wait for the batch inference to run.
                </td>
            </tr>`;
        totalCount.textContent = '0';
        healthyCount.textContent = '0';
        unhealthyCount.textContent = '0';
        return;
    }

    let healthy = 0;
    let unhealthy = 0;

    tableBody.innerHTML = '';
    data.forEach((record) => {
        const classification = record.classification || 'unknown';
        if (classification === 'healthy') healthy++;
        else if (classification === 'unhealthy') unhealthy++;

        const row = document.createElement('tr');
        row.innerHTML = `
            <td>${escapeHtml(record.citizen_id)}</td>
            <td>${formatNumber(record.average_heart_beat_rate)} bpm</td>
            <td>${formatPercent(record.o2_content)}</td>
            <td>${formatNumber(record.sleep_time)}h</td>
            <td>${formatNumber(record.calories_burned)} kcal</td>
            <td><span class="badge ${classification}">${classification}</span></td>
            <td>${formatTimestamp(record.inference_timestamp)}</td>
        `;
        tableBody.appendChild(row);
    });

    totalCount.textContent = data.length;
    healthyCount.textContent = healthy;
    unhealthyCount.textContent = unhealthy;
}

/**
 * Escape HTML to prevent XSS.
 */
function escapeHtml(str) {
    if (!str) return '';
    const div = document.createElement('div');
    div.appendChild(document.createTextNode(str));
    return div.innerHTML;
}

/**
 * Format a number to 2 decimal places (or integer).
 */
function formatNumber(val) {
    if (val === null || val === undefined) return '-';
    const num = Number(val);
    return Number.isInteger(num) ? num.toString() : num.toFixed(2);
}

/**
 * Format a float as a percentage.
 */
function formatPercent(val) {
    if (val === null || val === undefined) return '-';
    return (Number(val) * 100).toFixed(1) + '%';
}

/**
 * Format an ISO timestamp to a locale-friendly string.
 */
function formatTimestamp(ts) {
    if (!ts) return '-';
    try {
        return new Date(ts).toLocaleString();
    } catch {
        return ts;
    }
}

// Initial fetch and periodic refresh
fetchData();
setInterval(fetchData, POLL_INTERVAL_MS);
