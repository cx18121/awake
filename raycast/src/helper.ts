import { execFile } from 'node:child_process';
import { launchCommand, LaunchType, LocalStorage } from '@raycast/api';

const helperPath = '/Library/PrivilegedHelperTools/dev.herdr.AgentAwakeHelper';
const batteryFloor = 20;
const keepDisplayOnKey = 'keep-display-on';

export type AwakeStatus = {
  active: boolean;
  batteryLevel: number | null;
  durationSeconds: number | null;
  remainingSeconds: number | null;
  keepDisplayOn: boolean;
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

const parseStatus = (value: unknown): AwakeStatus | null => {
  if (typeof value !== 'object' || value === null) {
    return null;
  }

  const active = 'active' in value ? value.active : undefined;
  const batteryLevel = 'batteryLevel' in value ? value.batteryLevel : null;
  const durationSeconds =
    'durationSeconds' in value ? value.durationSeconds : null;
  const remainingSeconds =
    'remainingSeconds' in value ? value.remainingSeconds : null;
  const keepDisplayOn =
    'keepDisplayOn' in value ? value.keepDisplayOn : undefined;

  if (
    typeof active !== 'boolean' ||
    !isNullableNumber(batteryLevel) ||
    !isNullableNumber(durationSeconds) ||
    !isNullableNumber(remainingSeconds) ||
    typeof keepDisplayOn !== 'boolean'
  ) {
    return null;
  }

  return {
    active,
    batteryLevel,
    durationSeconds,
    remainingSeconds,
    keepDisplayOn,
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
  durationSeconds: number | null,
  keepDisplayOn = false
) =>
  runHelper([
    'start',
    String(durationSeconds ?? 0),
    String(batteryFloor),
    keepDisplayOn ? '1' : '0',
  ]);

export const readKeepDisplayOnPreference = async () =>
  (await LocalStorage.getItem<boolean>(keepDisplayOnKey)) ?? false;

export const setKeepDisplayOn = async (keepDisplayOn: boolean) => {
  await runHelper(['display', keepDisplayOn ? '1' : '0']);
  await LocalStorage.setItem(keepDisplayOnKey, keepDisplayOn);
};

export const setKeepDisplayOnPreference = (keepDisplayOn: boolean) =>
  LocalStorage.setItem(keepDisplayOnKey, keepDisplayOn);

export const stopAwake = () => runHelper(['stop']);

export const refreshMenu = async () => {
  try {
    await launchCommand({ name: 'index', type: LaunchType.Background });
  } catch {
    return;
  }
};
