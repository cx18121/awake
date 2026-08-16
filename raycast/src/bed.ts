import { showHUD } from '@raycast/api';

import { refreshMenu, stopAwake } from './helper';

export default async function command() {
  await stopAwake();
  await refreshMenu();
  await showHUD('Sleeping normally');
}
