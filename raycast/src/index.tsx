import {
  Color,
  Icon,
  MenuBarExtra,
  showHUD,
  showToast,
  Toast,
} from '@raycast/api';
import { usePromise } from '@raycast/utils';
import { useEffect, useState } from 'react';

import {
  type AwakeStatus,
  readStatus,
  setKeepDisplayOn,
  startAwake,
  stopAwake,
} from './helper';

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
  const keepDisplayOn = status?.keepDisplayOn ?? false;
  const [, setTick] = useState(0);

  useEffect(() => {
    if (!status?.active || status.remainingSeconds === null) {
      return;
    }

    const timer = setInterval(() => setTick((tick) => tick + 1), 60_000);
    return () => clearInterval(timer);
  }, [status?.active, status?.observedAt, status?.remainingSeconds]);

  useEffect(() => {
    if (!status?.active || status.remainingSeconds === null) {
      return;
    }

    const expiresAt = status.observedAt + status.remainingSeconds * 1000;
    const timer = setTimeout(
      () => void statusQuery.revalidate(),
      Math.max(0, expiresAt - Date.now() + 10_500)
    );
    return () => clearTimeout(timer);
  }, [
    status?.active,
    status?.observedAt,
    status?.remainingSeconds,
    statusQuery.revalidate,
  ]);

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
  const inactiveStatus: AwakeStatus = {
    active: false,
    durationSeconds: null,
    remainingSeconds: null,
    keepDisplayOn,
    observedAt: Date.now(),
  };

  const run = async (
    action: Promise<string>,
    optimisticStatus: AwakeStatus
  ) => {
    try {
      await statusQuery.mutate(action, {
        optimisticUpdate: () => optimisticStatus,
      });
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: 'Awake could not change the sleep setting',
        message: errorMessage(error),
      });
    }
  };

  const goToBed = async () => {
    await showHUD('Bed');
    await run(stopAwake(), inactiveStatus);
  };

  const selectDuration = async (
    durationSeconds: number | null,
    durationTitle: string
  ) => {
    const isSelected =
      status?.active && status.durationSeconds === durationSeconds;
    const activeStatus: AwakeStatus = {
      active: true,
      durationSeconds,
      remainingSeconds: durationSeconds,
      keepDisplayOn,
      observedAt: Date.now(),
    };
    if (isSelected) {
      await goToBed();
      return;
    }

    await showHUD(
      durationSeconds === null
        ? 'Awake indefinitely'
        : `Awake for ${durationTitle.toLowerCase()}`
    );
    await run(startAwake(durationSeconds), activeStatus);
  };

  const toggleDisplay = async () => {
    const nextValue = !keepDisplayOn;
    const shouldStartAwake = nextValue && !status?.active;
    const action = shouldStartAwake
      ? startAwake(null).then(() => setKeepDisplayOn(true))
      : setKeepDisplayOn(nextValue);
    try {
      await statusQuery.mutate(action, {
        optimisticUpdate: (currentStatus) =>
          currentStatus
            ? {
                ...currentStatus,
                active: shouldStartAwake || currentStatus.active,
                durationSeconds: shouldStartAwake
                  ? null
                  : currentStatus.durationSeconds,
                remainingSeconds: shouldStartAwake
                  ? null
                  : currentStatus.remainingSeconds,
                keepDisplayOn: nextValue,
              }
            : currentStatus,
      });
      await showHUD(
        shouldStartAwake
          ? 'Awake indefinitely · display stays on'
          : nextValue
            ? 'Display stays on'
            : 'Display sleeps normally'
      );
    } catch (error) {
      await showToast({
        style: Toast.Style.Failure,
        title: 'Awake could not change the display setting',
        message: errorMessage(error),
      });
    }
  };

  return (
    <MenuBarExtra
      icon={
        statusQuery.error
          ? Icon.Warning
          : status?.active
            ? Icon.Bolt
            : { source: 'bed.svg', tintColor: Color.PrimaryText }
      }
      isLoading={statusQuery.isLoading}
      tooltip={
        statusQuery.error
          ? 'Awake unavailable'
          : status?.active
            ? remainingLabel
              ? `Awake · ${remainingLabel}`
              : 'Awake'
            : 'Bed'
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
          {status?.active ? (
            <MenuBarExtra.Item title="Bed" onAction={goToBed} />
          ) : null}
          <MenuBarExtra.Section>
            {durations.map((duration) => {
              const isSelected =
                status?.active && status.durationSeconds === duration.seconds;
              return (
                <MenuBarExtra.Item
                  key={duration.title}
                  title={duration.title}
                  subtitle={
                    isSelected ? (remainingLabel ?? undefined) : undefined
                  }
                  icon={isSelected ? Icon.Checkmark : undefined}
                  onAction={() =>
                    selectDuration(duration.seconds, duration.title)
                  }
                />
              );
            })}
          </MenuBarExtra.Section>
          <MenuBarExtra.Section>
            <MenuBarExtra.Item
              title="Keep Display On"
              icon={keepDisplayOn ? Icon.Checkmark : undefined}
              onAction={toggleDisplay}
            />
          </MenuBarExtra.Section>
        </>
      )}
    </MenuBarExtra>
  );
}
