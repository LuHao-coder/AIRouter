import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const DEVICE_ID_PREFS_NAME: string = 'ai_router_device';
const DEVICE_ID_PREFS_KEY: string = 'device_id';

let cachedDeviceId: string = '';

function generateUUID(): string {
  const chars = '0123456789abcdef';
  let uuid = '';
  for (let i = 0; i < 36; i++) {
    if (i === 8 || i === 13 || i === 18 || i === 23) {
      uuid += '-';
    } else {
      const randomIndex = Math.floor(Math.random() * 16);
      uuid += chars.charAt(randomIndex);
    }
  }
  return uuid;
}

export async function getDeviceId(context: common.Context): Promise<string> {
  if (cachedDeviceId.length > 0) {
    return cachedDeviceId;
  }

  try {
    const store = await preferences.getPreferences(context, DEVICE_ID_PREFS_NAME);
    const saved = await store.get(DEVICE_ID_PREFS_KEY, '');
    if (typeof saved === 'string' && saved.trim().length > 0) {
      cachedDeviceId = saved.trim();
      return cachedDeviceId;
    }
  } catch (error) {
  }

  const newId = generateUUID();
  cachedDeviceId = newId;

  try {
    const store = await preferences.getPreferences(context, DEVICE_ID_PREFS_NAME);
    await store.put(DEVICE_ID_PREFS_KEY, newId);
    await store.flush();
  } catch (error) {
  }

  return newId;
}
