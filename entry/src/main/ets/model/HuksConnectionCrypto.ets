import { huks } from '@kit.UniversalKeystoreKit';
import { buffer, util } from '@kit.ArkTS';

const CONNECTION_KEY_ALIAS: string = 'codex_router_connection_store_key';
const ENCRYPTED_STORE_PREFIX: string = 'ENC1:';
const GCM_TAG_LENGTH: number = 16;
const GCM_NONCE_LENGTH: number = 12;

function connectionKeyParams(): huks.HuksParam[] {
  return [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
    {
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
    },
    { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
    { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM }
  ];
}

function cipherParams(purpose: huks.HuksKeyPurpose, nonce: Uint8Array | null, tag: Uint8Array | null): huks.HuksParam[] {
  const params: huks.HuksParam[] = [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
    { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
    { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM }
  ];

  if (nonce !== null) {
    params.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce });
  }

  if (tag !== null) {
    params.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag });
  }

  return params;
}

async function ensureConnectionKey(): Promise<void> {
  try {
    await huks.generateKeyItem(CONNECTION_KEY_ALIAS, { properties: connectionKeyParams() });
  } catch (error) {
  }
}

function utf8Encode(value: string): Uint8Array {
  const textEncoder = new util.TextEncoder();
  return textEncoder.encodeInto(value);
}

function utf8Decode(value: Uint8Array): string {
  const textDecoder = new util.TextDecoder('utf-8');
  return textDecoder.decodeToString(value);
}

function copyBufferToBytes(value: buffer.Buffer): Uint8Array {
  const bytes = new Uint8Array(value.length);
  for (let i = 0; i < value.length; i++) {
    bytes[i] = value[i];
  }
  return bytes;
}

export function isEncryptedConnectionStore(storedValue: string): boolean {
  return storedValue.startsWith(ENCRYPTED_STORE_PREFIX);
}

export async function encryptConnectionStore(plainText: string): Promise<string> {
  try {
    const options: huks.HuksOptions = {
      properties: cipherParams(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, null, null),
      inData: utf8Encode(plainText)
    };

    await ensureConnectionKey();
    const handle = await huks.initSession(CONNECTION_KEY_ALIAS, options);
    const finish = await huks.finishSession(handle.handle, options);
    const outData = finish.outData;

    if (outData === undefined || outData.length === 0) {
      throw new Error('Failed to encrypt connection store');
    }

    return ENCRYPTED_STORE_PREFIX + buffer.from(outData).toString('base64');
  } catch (error) {
    throw new Error('Failed to encrypt connection store');
  }
}

export async function decryptConnectionStore(storedValue: string): Promise<string | null> {
  if (!isEncryptedConnectionStore(storedValue)) {
    return null;
  }

  let blob: Uint8Array;
  try {
    const decoded = buffer.from(storedValue.substring(ENCRYPTED_STORE_PREFIX.length), 'base64');
    blob = copyBufferToBytes(decoded);
  } catch (error) {
    return null;
  }

  const minimumLength: number = GCM_NONCE_LENGTH + GCM_TAG_LENGTH;
  if (blob.length < minimumLength) {
    return null;
  }

  const nonce = blob.subarray(blob.length - GCM_NONCE_LENGTH);
  const tag = blob.subarray(blob.length - GCM_NONCE_LENGTH - GCM_TAG_LENGTH, blob.length - GCM_NONCE_LENGTH);
  const cipher = blob.subarray(0, blob.length - GCM_NONCE_LENGTH - GCM_TAG_LENGTH);
  const options: huks.HuksOptions = {
    properties: cipherParams(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, nonce, tag),
    inData: cipher
  };

  try {
    const handle = await huks.initSession(CONNECTION_KEY_ALIAS, options);
    const finish = await huks.finishSession(handle.handle, options);
    const outData = finish.outData;

    if (outData === undefined || outData.length === 0) {
      return null;
    }

    return utf8Decode(outData);
  } catch (error) {
    return null;
  }
}
