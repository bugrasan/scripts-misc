// devcontainerId reference for the pm tests, copied from the pm v8 spec
// (devcontainers/cli src/spec-common/variableSubstitution.ts, commit 0d38c68)
// usage: node devcontainer-id.js <local-folder>...
// prints one id per folder, for the config file
// <local-folder>/.devcontainer/devcontainer.json
'use strict';
const crypto = require('crypto');

function devcontainerIdForLabels(idLabels) {
  const stringInput = JSON.stringify(idLabels, Object.keys(idLabels).sort());
  const bufferInput = Buffer.from(stringInput, 'utf-8');
  const hash = crypto.createHash('sha256').update(bufferInput).digest();
  return BigInt(`0x${hash.toString('hex')}`).toString(32).padStart(52, '0');
}

for (const folder of process.argv.slice(2)) {
  console.log(devcontainerIdForLabels({
    'devcontainer.local_folder': folder,
    'devcontainer.config_file': folder + '/.devcontainer/devcontainer.json',
  }));
}
