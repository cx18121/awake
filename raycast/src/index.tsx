import {
  Color,
  Icon,
  MenuBarExtra,
  showHUD,
  showToast,
  Toast,
} from '@raycast/api';
import { usePromise } from '@raycast/utils';

import { type AwakeMode, readStatus, startAwake, stopAwake } from './helper';

const durations = [
  { title: 'Indefinitely', seconds: null },
  { title: '10 Minutes', seconds: 600 },
  { title: '30 Minutes', seconds: 1800 },
  { title: '1 Hour', seconds: 3600 },
  { title: '2 Hours', seconds: 7200 },
  { title: '4 Hours', seconds: 14_400 },
  { title: '8 Hours', seconds: 28_800 },
  { title: '12 Hours', seconds: 43_200 },
];

const modes = [
  {
    mode: 'screen',
    title: 'Keep Screen On',
    description: 'Sleeps when the lid closes',
    icon: Icon.Sun,
  },
  {
    mode: 'agents',
    title: 'Keep Agents Running',
    description: 'Works with the lid closed; screen may turn off',
    icon: Icon.Terminal,
  },
  {
    mode: 'everything',
    title: 'Keep Everything On',
    description: 'Screen stays on while open; works with the lid closed',
    icon: Icon.Bolt,
  },
] satisfies {
  mode: AwakeMode;
  title: string;
  description: string;
  icon: Icon;
}[];

const errorMessage = (error: unknown) =>
  error instanceof Error
    ? error.message
    : 'Awake could not change the sleep setting.';

const formatDuration = (totalSeconds: number) => {
  const totalMinutes = Math.ceil(totalSeconds / 60);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  const parts = [
    { amount: hours, unit: 'h' },
    { amount: minutes, unit: 'm' },
  ]
    .filter(({ amount }) => amount > 0)
    .map(({ amount, unit }) => `${amount}${unit}`);

  return parts.length > 0 ? parts.join(' ') : '0m';
};

export default function Command() {
  const statusQuery = usePromise(readStatus);
  const status = statusQuery.data;

  const remainingSeconds =
    status?.remainingSeconds === null || status?.remainingSeconds === undefined
      ? null
      : Math.max(
          0,
          status.remainingSeconds -
            Math.floor((Date.now() - status.observedAt) / 1000)
        );
  const remainingLabel =
    remainingSeconds === null
      ? null
      : remainingSeconds === 0
        ? 'Ending…'
        : `${formatDuration(remainingSeconds)} left`;
  const activeMode = status?.active ? status.mode : null;
  const activeModeOption = modes.find(({ mode }) => mode === activeMode);
  const run = async (action: Promise<string>, successMessage: string) => {
    try {
      await action;
      await showHUD(successMessage);
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: 'Awake could not change the sleep setting',
        message: errorMessage(error),
      });
    }
  };

  const sleepNormally = () => run(stopAwake(), 'Sleeping normally');

  const selectMode = async (
    mode: AwakeMode,
    modeTitle: string,
    durationSeconds: number | null,
    durationTitle: string
  ) => {
    const successMessage =
      durationSeconds === null
        ? `${modeTitle} indefinitely`
        : `${modeTitle} for ${durationTitle.toLowerCase()}`;
    await run(startAwake(mode, durationSeconds), successMessage);
  };

  return (
    <MenuBarExtra
      icon={
        statusQuery.error
          ? Icon.Warning
          : activeModeOption?.icon ?? {
              source: 'bed.svg',
              tintColor: Color.PrimaryText,
            }
      }
      isLoading={statusQuery.isLoading}
      tooltip={
        statusQuery.error
          ? 'Awake unavailable'
          : activeModeOption
            ? remainingLabel
              ? `${activeModeOption.title} · ${remainingLabel}`
              : activeModeOption.title
            : 'Sleeping Normally'
      }
    >
      {statusQuery.isLoading ? null : (
        <>
          {statusQuery.error ? (
            <MenuBarExtra.Item
              title="Awake is unavailable"
              icon={Icon.Warning}
            />
          ) : null}
          <MenuBarExtra.Item
            title="Sleep Normally"
            subtitle="Display and Mac sleep normally"
            icon={status?.active === false ? Icon.Checkmark : undefined}
            onAction={sleepNormally}
          />
          <MenuBarExtra.Section>
            {modes.map((modeOption) => (
              <MenuBarExtra.Submenu
                key={modeOption.mode}
                title={modeOption.title}
                icon={
                  activeMode === modeOption.mode
                    ? Icon.Checkmark
                    : modeOption.icon
                }
              >
                <MenuBarExtra.Item title={modeOption.description} />
                <MenuBarExtra.Section>
                  {durations.map((duration) => {
                    const isSelected =
                      activeMode === modeOption.mode &&
                      status?.durationSeconds === duration.seconds;
                    return (
                      <MenuBarExtra.Item
                        key={duration.title}
                        title={duration.title}
                        subtitle={
                          isSelected ? (remainingLabel ?? undefined) : undefined
                        }
                        icon={isSelected ? Icon.Checkmark : undefined}
                        onAction={() =>
                          selectMode(
                            modeOption.mode,
                            modeOption.title,
                            duration.seconds,
                            duration.title
                          )
                        }
                      />
                    );
                  })}
                </MenuBarExtra.Section>
              </MenuBarExtra.Submenu>
            ))}
          </MenuBarExtra.Section>
        </>
      )}
    </MenuBarExtra>
  );
}
