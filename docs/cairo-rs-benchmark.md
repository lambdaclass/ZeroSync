# Benchmarking using Cairo-rs
This is a guide to run ZeroSync tests using the cairo-rs VM instead of the Python implementation. 

## 1. Environment Configuration
To configure both the modified pyenv with the Cairo-rs VM and the Python VM follow [this guide](https://github.com/lambdaclass/cairo-rs-py#script-to-try-out-cairo-rs-py). 

## 2. Building protostar
ZeroSync uses Protostar, the Starknet contracts toolchain to run the tests. To use the Rust VM implementation we should patch a file inside protostar to use the new CairoRunner. To do this we included in this repository a patch to apply directly to change what is needed. 

```bash
git clone git@github.com:software-mansion/protostar.git
cd protostar
poetry install
patch -p 1 < 0001-patch-cairo-rs-py-runner-into-cheatable-runner.patch
poe build
```

## 3. Testing ZeroSync
Now the only thing left would be to checkout to `cairo-rs-benchmark` in the Lambda/ZeroSync Fork and use the protostar we built in the previous step to run the tests. 

```bash
<your_home_dir>/protostar/dist/protostar/protostar test  --cairo-path=./src target src
```

