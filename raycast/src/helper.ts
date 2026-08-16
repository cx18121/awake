import { execFile } from 'node:child_process';
import { launchCommand, LaunchType } from '@raycast/api';

const helperPath = '/Library/PrivilegedHelperTools/dev.herdr.AgentAwakeHelper';
const batteryFloor = 20;

export type AwakeMode = 'screen' | 'agents' | 'everything';

export type AwakeStatus = {
  active: boolean;
  mode: AwakeMode | null;
  durationSeconds: number | null;
  remainingSeconds: number | null;
  observedAt: number;
};

const runHelper = (arguments_: string[]) =>
  new Promise<string>((resolve, reject) => {
    execFile(
      '/usr/bin/sudo',
      ['-n', helperPath, ...arguments_],
      (error, stdout, stderr) => {
        if (error) {
          reject(new Error(stderr.trim() || error.message));
          return;
        }

        resolve(stdout.trim());
      }
    );
  });

const isNullableNumber = (value: unknown): value is number | null =>
  value === null || typeof value === 'number';

const isAwakeMode = (value: unknown): value is AwakeMode | null =>
  value === null ||
  value === 'screen' ||
  value === 'agents' ||
  value === 'everything';

const parseStatus = (value: unknown): AwakeStatus | null => {
  if (typeof value !== 'object' || value === null) {
    return null;
  }

  const active = 'active' in value ? value.active : undefined;
  const mode = 'mode' in value ? value.mode : null;
  const durationSeconds =
    'durationSeconds' in value ? value.durationSeconds : null;
  const remainingSeconds =
    'remainingSeconds' in value ? value.remainingSeconds : null;

  if (
    typeof active !== 'boolean' ||
    !isAwakeMode(mode) ||
    !isNullableNumber(durationSeconds) ||
    !isNullableNumber(remainingSeconds)
  ) {
    return null;
  }

  return {
    active,
    mode,
    durationSeconds,
    remainingSeconds,
    observedAt: Date.now(),
  };
};

export const readStatus = async () => {
  const value: unknown = JSON.parse(await runHelper(['status']));
  const status = parseStatus(value);
  if (!status) {
    throw new Error('Awake returned an invalid status.');
  }

  return status;
};

export const startAwake = (
  mode: AwakeMode,
  durationSeconds: number | null
) =>
  runHelper([
    'start',
    mode,
    String(durationSeconds ?? 0),
    String(batteryFloor),
  ]);

export const stopAwake = () => runHelper(['stop']);

export const refreshMenu = async () => {
  try {
    await launchCommand({ name: 'index', type: LaunchType.Background });
  } catch {
    return;
  }
};
