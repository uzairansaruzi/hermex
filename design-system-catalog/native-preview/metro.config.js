// Dev-only harness: lets Metro resolve the shared `native/`, `tokens/`, and `icons/` folders that
// live outside this app's root (siblings under design-system-template/), and lets those files'
// `import 'react'` etc. resolve against this app's node_modules despite not being an ancestor dir.
const { getDefaultConfig } = require('expo/metro-config');
const path = require('path');

const projectRoot = __dirname;
const templateRoot = path.resolve(projectRoot, '..');

const config = getDefaultConfig(projectRoot);

config.watchFolders = [templateRoot];
config.resolver.nodeModulesPaths = [path.resolve(projectRoot, 'node_modules')];

module.exports = config;
