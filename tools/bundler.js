let chokidar = require('chokidar');
let fs = require('fs');

let header = `
local modules = {}
local pendingModules = {}
local function wrapRequire(path)
	if modules[path] == nil then
		if pendingModules[path] == nil then
			modules[path] = require(path)
		else
			modules[path] = pendingModules[path](wrapRequire)
			pendingModules[path] = nil
		end
	end
	return modules[path]
end`;

let footer = ``;
let rootPath = process.argv[2]; // ./src
let distPath = process.argv[3]; // ./dist/Blackprint.lua
let entryFile = '@src/init.lua';
let lib = {/*
	"./path.lua": "local lua = module"
*/};

if(!rootPath || !distPath) throw new Error("Required CLI parameter was not found");

chokidar.watch(rootPath, {
	persistent: process.argv[4] === '--compile' ? false : true,
	ignored: /\.txt|\.git/,
	atomic: true,
	depth: 5,
	followSymlinks: true,
})
.on('add', (path) => {console.log(`${path} has been added`); reloadFile('add', path); rebundle()})
.on('change', (path) => {console.log(`${path} has been changed`); reloadFile('change', path); rebundle()})
.on('unlink', (path) => {console.log(`${path} has been removed`); reloadFile('unlink', path); rebundle()})
.on('error', (error) => console.log(`Watcher error: ${error}`))
.on('ready', () => {console.log('Initial scan complete. Ready for changes'); rebundle(true)});

function reloadFile(method, path){
	path = path.split('\\').join('/');

	let root = rootPath.replace('./', '');
	let tablePath = path.replace(root, 'src');

	if(method === 'unlink') delete lib[path];
	if(method === 'change' || method === 'add') lib[tablePath] = fs.readFileSync(process.cwd() + '/' + path, 'utf8');
}

let _debounce = 0;
let init = false;
function rebundle(isInitial){
	if(!init && !isInitial) return;
	init = true;

	clearTimeout(_debounce);
	setTimeout(() => {
		let bundled = '';

		for (let path in lib) {
			if(!lib[path] || lib[path].constructor !== String) throw new Error(`${path} is not defined`);

			let val = '\t'+lib[path].split('\n').join('\n\t');
			val = val.split('\n\t\n').join('\n\n');

			path = path.split('\\').join('/');
			bundled += `\npendingModules["@${path}"] = function(require)\n${val}\nend`;
		}

		bundled += `\nmodules["${entryFile}"] = pendingModules["${entryFile}"](wrapRequire)\nreturn modules["${entryFile}"]`

		if(bundled) fs.writeFileSync(distPath, header + bundled + footer);
	}, 500);
}