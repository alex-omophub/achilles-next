import {createHash} from 'node:crypto';

export function verifyTerminologyLock(lock, bytes) {
  if (lock.contract_version !== '2.1.0' || lock.extension_version !== '1.0.0' ||
      Object.keys(lock.sha256 ?? {}).join() !== 'terminology.schema.json' ||
      createHash('sha256').update(bytes).digest('hex') !== lock.sha256['terminology.schema.json']) {
    throw new Error('Terminology schema integrity mismatch');
  }
}
