import { spawn } from 'node:child_process';
import { join } from 'node:path';

const shell = join(process.env.SystemRoot ?? 'C:/Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe');
const script = join(import.meta.dirname, 'boss-native.ps1');
const defaultMaxJobs = 50;
const maxJobs = (() => {
  const raw = process.argv.find(arg => arg.startsWith('--max='))?.slice('--max='.length)
    ?? process.env.BOSS_MAX_JOBS;
  const parsed = Number(raw);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : defaultMaxJobs;
})();

const child = spawn(shell, [
  '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', script,
], {
  stdio: 'inherit',
  env: {
    ...process.env,
    BOSS_SCRIPT_HOME: import.meta.dirname,
    BOSS_CHECK_ONLY: process.argv.includes('--check') ? '1' : '0',
    BOSS_DRY_RUN: process.argv.includes('--dry-run') ? '1' : '0',
    BOSS_MAX_JOBS: String(maxJobs),
  },
});
child.once('error', error => {
  console.error(error.message);
  process.exitCode = 1;
});
child.once('exit', code => { process.exitCode = code ?? 1; });
