import { huks } from '@kit.UniversalKeystoreKit';
import { BusinessError } from '@kit.BasicServicesKit';

const KEY_ALIAS: string = 'ai_router_device_auth';

function stringToUint8Array(str: string): Uint8Array {
  const result: number[] = [];
  for (let i = 0; i < str.length; i++) {
    result.push(str.charCodeAt(i) & 0xff);
  }
  return new Uint8Array(result);
}

function uint8ArrayToBase64(data: Uint8Array): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let result = '';
  for (let i = 0; i < data.length; i += 3) {
    const b0 = data[i];
    const b1 = i + 1 < data.length ? data[i + 1] : 0;
    const b2 = i + 2 < data.length ? data[i + 2] : 0;
    result += chars.charAt(b0 >> 2);
    result += chars.charAt(((b0 & 3) << 4) | (b1 >> 4));
    result += i + 1 < data.length ? chars.charAt(((b1 & 15) << 2) | (b2 >> 6)) : '=';
    result += i + 2 < data.length ? chars.charAt(b2 & 63) : '=';
  }
  return result;
}

function wrapDerInPem(derData: Uint8Array): string {
  const b64 = uint8ArrayToBase64(derData);
  const lines: string[] = [];
  for (let i = 0; i < b64.length; i += 64) {
    lines.push(b64.substring(i, i + 64));
  }
  return `-----BEGIN PUBLIC KEY-----\n${lines.join('\n')}\n-----END PUBLIC KEY-----`;
}

function buildEd25519SpkiDer(rawPublicKey: Uint8Array): Uint8Array {
  // Ed25519 OID: 1.3.101.112 = 0x2b 0x65 0x70
  // SPKI structure:
  // SEQUENCE {
  //   SEQUENCE { OID 1.3.101.112 }
  //   BIT STRING { 0x00 + rawPublicKey }
  // }

  let keyBytes = rawPublicKey;
  if (keyBytes.length === 33 && keyBytes[0] === 0x00) {
    keyBytes = keyBytes.slice(1);
  }

  const algorithmId = new Uint8Array([0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70]);

  const bitStringValue = new Uint8Array(1 + keyBytes.length);
  bitStringValue[0] = 0x00;
  bitStringValue.set(keyBytes, 1);

  const bitString = new Uint8Array(2 + bitStringValue.length);
  bitString[0] = 0x03;
  bitString[1] = bitStringValue.length;
  bitString.set(bitStringValue, 2);

  const contentLen = algorithmId.length + bitString.length;
  const sequence = new Uint8Array(2 + contentLen);
  sequence[0] = 0x30;
  sequence[1] = contentLen;
  sequence.set(algorithmId, 2);
  sequence.set(bitString, 2 + algorithmId.length);

  return sequence;
}

function getGenerateProperties(): huks.HuksParam[] {
  const properties: huks.HuksParam[] = [
    {
      tag: huks.HuksTag.HUKS_TAG_ALGORITHM,
      value: huks.HuksKeyAlg.HUKS_ALG_ED25519
    },
    {
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_VERIFY
    },
    {
      tag: huks.HuksTag.HUKS_TAG_KEY_SIZE,
      value: huks.HuksKeySize.HUKS_CURVE25519_KEY_SIZE_256
    }
  ];
  return properties;
}

function getSignProperties(): huks.HuksParam[] {
  const properties: huks.HuksParam[] = [
    {
      tag: huks.HuksTag.HUKS_TAG_ALGORITHM,
      value: huks.HuksKeyAlg.HUKS_ALG_ED25519
    },
    {
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_SIGN
    }
  ];
  return properties;
}

async function generateKey(): Promise<void> {
  const options: huks.HuksOptions = {
    properties: getGenerateProperties()
  };
  try {
    await huks.generateKeyItem(KEY_ALIAS, options);
  } catch (error) {
    throw new Error('Failed to generate device key');
  }
}

async function signData(data: Uint8Array): Promise<Uint8Array> {
  const options: huks.HuksOptions = {
    properties: getSignProperties(),
    inData: data
  };
  try {
    const sessionResult = await huks.initSession(KEY_ALIAS, options);
    const finishResult = await huks.finishSession(sessionResult.handle, options);
    return finishResult.outData as Uint8Array;
  } catch (error) {
    throw new Error('Failed to sign data');
  }
}

async function exportPublicKeyDer(): Promise<Uint8Array> {
  const emptyOptions: huks.HuksOptions = {
    properties: []
  };
  try {
    const result = await huks.exportKeyItem(KEY_ALIAS, emptyOptions);
    return result.outData as Uint8Array;
  } catch (error) {
    throw new Error('Failed to export device public key');
  }
}

export interface DeviceKeyPair {
  publicKeyPem: string;
}

let cachedKeyPair: DeviceKeyPair | null = null;

export async function ensureDeviceKeyPair(): Promise<DeviceKeyPair> {
  if (cachedKeyPair !== null) {
    return cachedKeyPair;
  }

  let rawKey: Uint8Array;
  try {
    rawKey = await exportPublicKeyDer();
  } catch {
    await generateKey();
    rawKey = await exportPublicKeyDer();
  }

  const spkiDer = buildEd25519SpkiDer(rawKey);
  const publicKeyPem = wrapDerInPem(spkiDer);
  cachedKeyPair = { publicKeyPem };
  return cachedKeyPair;
}

export async function signChallenge(challenge: string): Promise<string> {
  const data = stringToUint8Array(challenge);
  const sig = await signData(data);
  return uint8ArrayToBase64(sig);
}
