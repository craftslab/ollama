# Ollama Model Archive and Restore

This folder contains `archive.sh`, a Bash utility for exporting a specific local Ollama model from Ubuntu and restoring it on another Ubuntu machine without re-running `ollama pull`.

The script archives:

- The model manifest under `manifests/...`
- Every blob referenced by that manifest under `blobs/...`

This is intended for offline transfer of a model such as `llama3.2`.

## Requirements

- Ubuntu with Bash and `tar`
- Ollama already installed on both source and target machines
- Read access to the source Ollama model store
- Write access to the target Ollama model store
- `sudo` on the target machine if Ollama runs as a system service

## Common Ollama Model Store Paths on Ubuntu

The script detects the model store automatically in this order:

1. `OLLAMA_MODELS`
2. `/usr/share/ollama/.ollama/models`
3. `/var/lib/ollama/.ollama/models`
4. `$HOME/.ollama/models`

If needed, you can override the target path during restore.

## Usage

Make the script executable:

```bash
chmod +x ./archive.sh
```

Show help:

```bash
./archive.sh help
```

## Archive a Specific Model

Archive `llama3.2` with the default output name:

```bash
./archive.sh archive llama3.2
```

This creates:

```bash
llama3.2-archive.tgz
```

Archive with a custom output path:

```bash
./archive.sh archive llama3.2 /tmp/llama3.2.tgz
```

Archive a tagged or namespaced model:

```bash
./archive.sh archive gemma3:12b
./archive.sh archive myspace/mymodel:latest
```

## Transfer the Archive

Example using `scp`:

```bash
scp llama3.2-archive.tgz user@target-host:/tmp/
```

You can also use `rsync`, a USB drive, or any other file transfer method.

## Restore on Another Ubuntu Machine

Restore using the automatically detected Ollama model store:

```bash
sudo ./archive.sh restore /tmp/llama3.2-archive.tgz
```

Restore to a specific model store path:

```bash
sudo ./archive.sh restore /tmp/llama3.2-archive.tgz /usr/share/ollama/.ollama/models
```

During restore, the script:

- Extracts the archive into the target Ollama model store
- Tries to set ownership to the Ollama service user
- Restarts `ollama.service` when run as `root`

## Verify the Restored Model

After restore:

```bash
ollama list
ollama run llama3.2
```

## End-to-End Example

On the source machine:

```bash
cd /home/lemonjia/my-tmp/ollama/archive
chmod +x ./archive.sh
./archive.sh archive llama3.2
scp llama3.2-archive.tgz user@target-host:/tmp/
```

On the target machine:

```bash
cd /home/lemonjia/my-tmp/ollama/archive
sudo ./archive.sh restore /tmp/llama3.2-archive.tgz
ollama list
ollama run llama3.2
```

## Notes

- This script archives one model manifest and the blobs referenced by that manifest.
- Ollama may deduplicate blobs across models, so a blob can be shared by multiple local models.
- If the restored model does not appear immediately, restart Ollama manually:

```bash
sudo systemctl restart ollama
```

- If your Ollama setup uses a custom store path, set `OLLAMA_MODELS` or pass the destination store path explicitly during restore.

## Troubleshooting

Model manifest not found:

- Confirm the model exists locally with `ollama list`
- Confirm the model name includes the correct tag, such as `llama3.2:latest` or `gemma3:12b`

Permission denied during restore:

- Re-run restore with `sudo`
- Check ownership of the target model store

Blobs missing during archive:

- The local Ollama store may be incomplete or manually modified
- Re-pull the model with `ollama pull <model>` and archive again
