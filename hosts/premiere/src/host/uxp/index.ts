// The Host as Premiere provides it.

import type { Host } from "../host.ts";
import { createFiles } from "./files.ts";
import { http, secrets, shell, hostInfo } from "./system.ts";
import { timeline } from "./premiere.ts";
import { createMediaPlayer, fileUrl } from "../player.ts";

export async function createUxpHost(pluginVersion: string, media: HTMLVideoElement): Promise<Host> {
  return {
    files: await createFiles(),
    http,
    secrets,
    shell,
    player: createMediaPlayer(media, fileUrl),
    timeline,
    info: hostInfo(pluginVersion),
  };
}
