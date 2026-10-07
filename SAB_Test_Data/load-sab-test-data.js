#!/usr/bin/env node
/*
 * SAB test data loader (devscratchorg).
 * Why this exists: the CSVs use readable keys (e.g. HH-1010, com2) instead of Salesforce Ids.
 * This script swaps each key for the real Id, skips rows that already exist (safe to re-run),
 * and imports the files in dependency order with `sf data import bulk`.
 *
 * Usage (from the SAB_Test_Data folder):
 *   node load-sab-test-data.js --dry                 check the CSVs only, no org needed
 *   node load-sab-test-data.js                       load everything into devscratchorg
 *   node load-sab-test-data.js --org myAlias         use another org alias
 *   node load-sab-test-data.js --from 07             start at file 07 (after fixing an error)
 *   node load-sab-test-data.js --only 19,20          load only those file numbers
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync } = require('child_process');

const args = process.argv.slice(2);
const opt = (n, d) => { const i = args.indexOf('--' + n); return i >= 0 ? args[i + 1] : d; };
const DRY = args.includes('--dry');
const ORG = opt('org', 'devscratchorg');
const FROM = opt('from', '00');
const ONLY = opt('only', '') ? opt('only').split(',').map(s => s.trim().padStart(2, '0')) : null;
const COMPANY_KEY = 'com2'; // Accounting_Company__c.Company_Key__c of "Habib Hasan"
const DIR = __dirname;

const CO = { obj: 'Accounting_Company__c', field: 'Company_Key__c' };
const GL = { obj: 'GL_Account__c', field: 'Company_Account_Key__c' };
const DEPT = { obj: 'Department__c', field: 'Company_Department_Key__c' };
const CCTR = { obj: 'Cost_Center__c', field: 'Company_Cost_Center_Key__c' };
const PROFILE = { obj: 'Party_Accounting_Profile__c', field: 'Profile_Key__c' };
const EMPMT = { obj: 'Employment__c', field: 'Employment_Key__c' };
const PAYC = { obj: 'Pay_Component__c', field: 'Component_Key__c' };

const PLAN = [
  { file: '01_GL_Account__c', sobject: 'GL_Account__c', dedupe: ['Company_Account_Key__c'], lookups: { Company__c: CO } },
  { file: '02_Accounting_Period__c', sobject: 'Accounting_Period__c', dedupe: ['Company_Period_Key__c'], overlap: true, lookups: { Company__c: CO } },
  { file: '03_Department__c', sobject: 'Department__c', dedupe: ['Company_Department_Key__c'], lookups: { Company__c: CO } },
  { file: '04_Cost_Center__c', sobject: 'Cost_Center__c', dedupe: ['Company_Cost_Center_Key__c'], lookups: { Company__c: CO } },
  { file: '05_Payment_Term__c', sobject: 'Payment_Term__c', dedupe: ['Term_Key__c'], lookups: { Company__c: CO } },
  { file: '06_Account', sobject: 'Account', dedupe: ['Name'], lookups: {} },
  { file: '07_Party_Accounting_Profile__c', sobject: 'Party_Accounting_Profile__c', dedupe: ['Profile_Key__c'],
    lookups: { Company__c: CO, Account__c: { obj: 'Account', field: 'Name' }, AR_Control_Account__c: GL, AP_Control_Account__c: GL, Payment_Term__c: { obj: 'Payment_Term__c', field: 'Term_Key__c' } } },
  { file: '08_Tax_Code__c', sobject: 'Tax_Code__c', dedupe: ['Company__c', 'Code__c'], lookups: { Company__c: CO, Output_Tax_Account__c: GL, Input_Tax_Account__c: GL } },
  { file: '09_Tax_Rate__c', sobject: 'Tax_Rate__c', dedupe: ['Rate_Key__c'], lookups: { Tax_Code__c: { obj: 'Tax_Code__c', field: 'Code__c', scoped: true } } },
  { file: '10_Bank_Account__c', sobject: 'Bank_Account__c', dedupe: ['Masked_Account_Number__c'], lookups: { Company__c: CO, GL_Account__c: GL } },
  { file: '11_Asset_Category__c', sobject: 'Asset_Category__c', dedupe: ['Category_Key__c'],
    lookups: { Company__c: CO, Asset_Account__c: GL, Accumulated_Depreciation_Account__c: GL, Depreciation_Expense_Account__c: GL, Disposal_Gain_Loss_Account__c: GL } },
  { file: '12_Employee__c', sobject: 'Employee__c', dedupe: ['Employee_Reference__c'], lookups: {} },
  { file: '13_Employment__c', sobject: 'Employment__c', dedupe: ['Employment_Key__c'],
    lookups: { Company__c: CO, Employee__c: { obj: 'Employee__c', field: 'Employee_Reference__c' }, Department__c: DEPT, Cost_Center__c: CCTR } },
  { file: '14_Pay_Component__c', sobject: 'Pay_Component__c', dedupe: ['Component_Key__c'], lookups: { Company__c: CO, Expense_Account__c: GL, Liability_Account__c: GL } },
  { file: '15_Employee_Pay_Component__c', sobject: 'Employee_Pay_Component__c', dedupe: ['Employment__c', 'Pay_Component__c', 'Effective_From__c'],
    lookups: { Employment__c: EMPMT, Pay_Component__c: PAYC } },
  { file: '16_Benefit_Award__c', sobject: 'Benefit_Award__c', dedupe: ['Award_Key__c'], lookups: { Employment__c: EMPMT, Pay_Component__c: PAYC } },
  { file: '17_Report_Definition__c', sobject: 'Report_Definition__c', dedupe: ['Definition_Key__c'], lookups: { Company__c: CO } },
  { file: '18_Report_Mapping__c', sobject: 'Report_Mapping__c', dedupe: ['Report_Definition__c', 'Row_Key__c', 'GL_Account__c'],
    lookups: { Report_Definition__c: { obj: 'Report_Definition__c', field: 'Definition_Key__c' }, GL_Account__c: GL } },
  { file: '19_Journal_Entry__c', sobject: 'Journal_Entry__c', dedupe: ['Description__c'], period: true, lookups: { Company__c: CO } },
  { file: '20_Journal_Entry_Line__c', sobject: 'Journal_Entry_Line__c', dedupe: ['Journal_Entry__c', 'Line_Number__c'],
    lookups: { Journal_Entry__c: { obj: 'Journal_Entry__c', field: 'Description__c' }, GL_Account__c: GL, Department__c: DEPT, Cost_Center__c: CCTR } },
  { file: '21_Supplier_Bill__c', sobject: 'Supplier_Bill__c', dedupe: ['Vendor_Reference__c'], lookups: { Company__c: CO, Supplier_Profile__c: PROFILE } },
  { file: '22_Bill_Line__c', sobject: 'Bill_Line__c', dedupe: ['Supplier_Bill__c', 'Line_Number__c'],
    lookups: { Supplier_Bill__c: { obj: 'Supplier_Bill__c', field: 'Vendor_Reference__c' }, Expense_or_Asset_Account__c: GL } },
  { file: '23_Invoice__c', sobject: 'Invoice__c', dedupe: ['Legal_Number__c'], lookups: { Company__c: CO, Party_Profile__c: PROFILE } },
  { file: '24_Invoice_Line__c', sobject: 'Invoice_Line__c', dedupe: ['Invoice__c', 'Line_Number__c'],
    lookups: { Invoice__c: { obj: 'Invoice__c', field: 'Legal_Number__c' }, Revenue_Account__c: GL } },
];

// ---------- CSV helpers
function parseCsv(text) {
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\n') { row.push(f); rows.push(row); row = []; f = ''; }
    else if (c !== '\r') f += c;
  }
  if (f.length || row.length) { row.push(f); rows.push(row); }
  const header = rows.shift();
  return { header, rows: rows.filter(r => r.length > 1 || r[0] !== '') };
}
const esc = v => (/[",\n\r]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v);
const toCsv = (header, rows) => [header, ...rows].map(r => r.map(esc).join(',')).join('\n') + '\n';
const norm = v => (v === null || v === undefined ? '' : String(v).trim());
const q1 = s => "'" + String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";

// ---------- sf wrapper
function sf(cmd) {
  try { return JSON.parse(execSync('sf ' + cmd + ' --json', { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'pipe'] })); }
  catch (e) {
    let out = e.stdout ? String(e.stdout) : '';
    try { const j = JSON.parse(out); throw new Error(j.message || out); } catch (x) { if (x.message && !/JSON/.test(x.message)) throw x; }
    throw new Error((out || e.message || '').trim() + ' ' + (e.stderr || ''));
  }
}
function query(soql) {
  const r = sf(`data query --query "${soql}" --target-org ${ORG}`);
  return (r.result && r.result.records) || [];
}
function queryIn(obj, fields, keyField, values, extraWhere) {
  const out = []; const vals = [...new Set(values)];
  for (let i = 0; i < vals.length; i += 100) {
    const chunk = vals.slice(i, i + 100).map(q1).join(',');
    out.push(...query(`SELECT ${fields.join(', ')} FROM ${obj} WHERE ${keyField} IN (${chunk})${extraWhere ? ' AND ' + extraWhere : ''}`));
  }
  return out;
}

// ---------- main
function readPlan() {
  return PLAN.map(p => {
    const fp = path.join(DIR, p.file + '.csv');
    if (!fs.existsSync(fp)) throw new Error('Missing file ' + fp);
    const { header, rows } = parseCsv(fs.readFileSync(fp, 'utf8'));
    for (const c of [...Object.keys(p.lookups), ...p.dedupe]) if (!header.includes(c)) throw new Error(`${p.file}: column ${c} not found`);
    return { ...p, header, rows, num: p.file.slice(0, 2) };
  });
}

function run() {
  const plan = readPlan();
  if (DRY) {
    for (const p of plan) console.log(`${p.file}.csv  ${p.rows.length} rows  OK`);
    console.log('\nDry check passed. Run without --dry to load into ' + ORG + '.');
    return;
  }
  console.log(`Target org: ${ORG}   Company key: ${COMPANY_KEY}`);
  const company = query(`SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = ${q1(COMPANY_KEY)}`);
  if (!company.length) throw new Error(`No Accounting_Company__c with Company_Key__c = ${COMPANY_KEY}. Edit COMPANY_KEY at the top of this script and the Company__c column in the CSVs.`);

  for (const p of plan) {
    if (p.num < FROM || (ONLY && !ONLY.includes(p.num))) continue;
    const idx = Object.fromEntries(p.header.map((h, i) => [h, i]));
    let rows = p.rows.map(r => r.slice());

    // 1. resolve lookup columns key -> Id
    const errors = [];
    for (const [col, spec] of Object.entries(p.lookups)) {
      const raw = rows.map(r => r[idx[col]]).filter(v => v !== '');
      if (!raw.length) continue;
      const extra = spec.scoped ? `Company__r.Company_Key__c = ${q1(COMPANY_KEY)}` : '';
      const found = queryIn(spec.obj, ['Id', spec.field], spec.field, raw, extra);
      const map = new Map(found.map(x => [norm(x[spec.field]), x.Id]));
      rows.forEach((r, n) => {
        const v = r[idx[col]]; if (v === '') return;
        if (map.has(v)) r[idx[col]] = map.get(v); else errors.push(`row ${n + 2}: ${col}="${v}" not found in ${spec.obj}.${spec.field}`);
      });
    }
    // period by accounting date
    if (p.period) {
      const periods = query(`SELECT Id, Start_Date__c, End_Date__c, Status__c FROM Accounting_Period__c WHERE Company__r.Company_Key__c = ${q1(COMPANY_KEY)}`);
      rows.forEach((r, n) => {
        const d = r[idx.Accounting_Date__c];
        const hit = periods.find(x => x.Start_Date__c <= d && d <= x.End_Date__c && x.Status__c === 'Open');
        if (hit) r[idx.Accounting_Period__c] = hit.Id; else errors.push(`row ${n + 2}: no Open Accounting Period contains ${d}`);
      });
    }
    if (errors.length) { console.error(`\n${p.file}: cannot load\n  ` + errors.slice(0, 15).join('\n  ') + (errors.length > 15 ? `\n  ...and ${errors.length - 15} more` : '')); process.exit(1); }

    // 2. skip rows that already exist
    let skipped = 0;
    const key = r => p.dedupe.map(c => norm(r[idx[c]])).join('|');
    const first = p.dedupe[0];
    const exist = queryIn(p.sobject, p.dedupe, first, rows.map(r => r[idx[first]]));
    const have = new Set(exist.map(x => p.dedupe.map(c => norm(x[c])).join('|')));
    rows = rows.filter(r => { if (have.has(key(r))) { skipped++; return false; } return true; });

    // 3. periods: skip date ranges that overlap an existing period
    if (p.overlap) {
      const ex = query(`SELECT Start_Date__c, End_Date__c FROM Accounting_Period__c WHERE Company__r.Company_Key__c = ${q1(COMPANY_KEY)}`);
      rows = rows.filter(r => {
        const s = r[idx.Start_Date__c], e = r[idx.End_Date__c];
        if (ex.some(x => s <= x.End_Date__c && e >= x.Start_Date__c)) { skipped++; console.log(`  skip period ${r[idx.Period_Key__c]}: overlaps an existing period`); return false; }
        return true;
      });
    }

    if (!rows.length) { console.log(`${p.file}: nothing to load (${skipped} already present)`); continue; }

    // 4. import
    const tmp = path.join(os.tmpdir(), `sab-${p.file}-${Date.now()}.csv`);
    fs.writeFileSync(tmp, toCsv(p.header, rows));
    let res;
    try { res = sf(`data import bulk --sobject ${p.sobject} --file "${tmp}" --target-org ${ORG} --line-ending LF --wait 10`); }
    catch (e) { console.error(`\n${p.file}: import failed\n${e.message}`); process.exit(1); }
    const info = (res.result && res.result.jobInfo) || {};
    const failed = Number(info.numberRecordsFailed || 0);
    console.log(`${p.file}: loaded ${Number(info.numberRecordsProcessed || rows.length) - failed}, skipped ${skipped} existing${failed ? `, FAILED ${failed}` : ''}`);
    if (failed) {
      console.error(`  Job ${info.id}. See the reasons with:  sf data bulk results --job-id ${info.id} --target-org ${ORG}\n  Fix the cause, then re-run with --from ${p.num} (already-loaded rows are skipped).`);
      process.exit(1);
    }
  }
  console.log('\nDone. Next: post the 6 draft journals in the Journal Workspace, then approve and post bills and invoices.');
}
try { run(); } catch (e) { console.error('\nERROR: ' + e.message); process.exit(1); }
