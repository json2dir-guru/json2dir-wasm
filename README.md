# json2dir-wasm

json2dir written by hand in WebAssembly text (`json2dir.wat`, WASI preview1), run by Bun; `run.js` only hosts it (chmod, plus lstat/unlink for symlinks pointing outside, which Bun's WASI mishandles).

    wat2wasm -o out/json2dir.wasm json2dir.wat && bun run.js < document.json
