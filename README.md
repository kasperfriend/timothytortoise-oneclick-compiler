# Tortoise WoW One-Click Compiler

Run a local [Turtle WoW](https://turtle-wow.org/) server. This stack uses [T-imothy/tortoise-wow](https://github.com/T-imothy/tortoise-wow) with playerbots.


This repository includes a bundle of scripts used for compiling a working server and transferring your characters and data from my previous iterations(Native Windows server or Docker build)

## What you need

- Git(auto-installs, but if fails - install manually)
- CMake(auto-installs, but if fails - install manually)
- VS Community or Build Tools with Desktop Development with C++(auto-installs, but if fails - install manually)
- A Turtle WoW **1.18.1** client (**build 7272**)
- Client data folders: `dbc`, `maps`, `vmaps`, `mmaps`
- Several GB of free disk space

The repo does not include client data. You extract that data from your game client. The video shows how to get them.

## Quick start

### 1. Get the repo files

```bash
git clone https://github.com/kasperfriend/timothytortoise-oneclick-compiler
cd timothytortoise-oneclick-compiler
```

### 2. Assuming you have requirements

```bash
compile-tortoise.bat
```
It will download everything it needs, compile the whole server and automatically close

### 3.1 (optional) Extract client data

Put all extractors into game client folder and run: 1) mapextractor 2) vmapextractor 3) vmap_assembler 4) MoveMapGen(this is the longest, may take a lot of time!)

### 3.2 Add client data

Put the extracted folders(dbc, maps, vmaps and mmaps) directly into server folder, near mangosd.exe

### 4. Edit configs(important)

By default, configs will feature dev settings, which may cause lag and instability and may actually crash mangosd. I have included recommended conf files for mangosd and aiplayerbot and realmd, you can compare them, tweak how you like it and replace default ones, but it's recommended to do before first launch!

You will need to manually create folders data, logs, honor and pdump or replace lines 12, 16, 20, 24 in mangosd.conf to be equal "." to avoid crashing mangosd

### 5. Create a game account and promote it

Inside mangosd.exe console type: account create username password, and to promote type: account set gmlevel username 4 -1

Change credentials if needed, and DON'T WORRY if the stream of data interrupts you - that's fine, continue typing and don't try to retype, it will still accept the right command

### 6. Connect with the client

Edit `realmlist.wtf` in your Turtle WoW client:

```text
set realmlist 127.0.0.1
```

### 7. Start the server

You can easily start the server with these steps: 1) Run start-database.bat 2) Run realmd.exe in server folder 3) Run mangosd.exe in server folder

It will apply a LONG list of SQL migrations on first launch, which may take around 20 minutes. After you hear a Windows beep sound it's ready to create account and enter the game.


## Troubleshooting

| Problem | What to do |
|---|---|
| Login fails / unknown account | Wait for `World server is up and running`, then create the account again |
| Account create does nothing | mangosd is still starting; wait and retry |
| Realm list is empty or offline | Check that `realmd` and `mangosd` are up: `docker compose ps` |
| Client hangs after you pick the realm | Set `REALM_ADDRESS` to an IP the client can reach; world port is `8090` |
| Empty world / no NPCs | First database import failed; check `docker compose logs db-init` |
| No bots | Use `TAG=playerbots` and `AI_PLAYERBOT_ENABLED=1` |
| Client crash: interface corrupt | Use the published image from this project; do not strip Turtle addons |

## Credits

- Setup walkthrough: [YouTube video](https://www.youtube.com/watch?v=CNgkHs3btNE)
- Server source: [Shyalya/tortoise-wow](https://github.com/Shyalya/tortoise-wow)
- Install notes: [INSTALL-LINUX.md](https://github.com/Shyalya/tortoise-wow/blob/playerbots-integration-gh/INSTALL-LINUX.md)

Server code stays under the upstream project license. This repository only provides the Docker packaging.
