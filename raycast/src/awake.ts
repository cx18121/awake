import { showHUD } from '@raycast/api';

import { readKeepDisplayOnPreference, refreshMenu, startAwake } from './helper';

export default async function command() {
  await startAwake(null, await readKeepDisplayOnPreference());
  await refreshMenu();
  await showHUD('Awake');
}
