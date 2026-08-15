import { showHUD } from '@raycast/api';

import { refreshMenu, startAwake } from './helper';

export default async function command() {
  await startAwake(null);
  await refreshMenu();
  await showHUD('Awake');
}
