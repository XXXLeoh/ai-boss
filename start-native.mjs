import { spawn } from 'node:child_process';
import { join } from 'node:path';

const shell = join(process.env.SystemRoot ?? 'C:/Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe');
const child = spawn(shell, [
  '-NoProfile', '-STA', '-Command',
  ". ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $env:BOSS_SCRIPT_HOME 'boss-native.ps1'))))",
], {
  stdio: 'inherit',
  env: {
    ...process.env,
    BOSS_SCRIPT_HOME: import.meta.dirname,
    BOSS_CHECK_ONLY: process.argv.includes('--check') ? '1' : '0',
  },
});
child.once('error', error => {
  console.error(error.message);
  process.exitCode = 1;
});
child.once('exit', code => { process.exitCode = code ?? 1; });
