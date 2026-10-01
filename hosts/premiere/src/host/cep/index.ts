// The Host as a CEP panel provides it.

import type { Host } from "../host.ts";
import { createFiles, http, secrets, shell, hostInfo } from "./system.ts";
import { timeline } from "./premiere.ts";
import { createMediaPlayer, fileUrl } from "../player.ts";
import { createWebAudioRecorder } from "../webaudio-recorder.ts";

export function createCepHost(pluginVersion: string, media: HTMLVideoElement): Host {
  return {
    files: createFiles(),
    http,
    secrets,
    shell,
    player: createMediaPlayer(media, fileUrl),
    timeline,
    info: hostInfo(pluginVersion),
    recorder: createWebAudioRecorder(),
  };
}
