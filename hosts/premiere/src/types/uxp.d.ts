// The parts of UXP's own modules this plugin uses, typed by hand from
// Adobe's reference (developer.adobe.com/premiere-pro/uxp/uxp-api). Kept
// small on purpose: it is a list of what the plugin depends on.

declare module "uxp" {
  interface Entry {
    readonly name: string;
    readonly nativePath: string;
    readonly isFile: boolean;
    readonly isFolder: boolean;
  }
  interface FileTypes {
    readonly all: string[];
  }
  interface LocalFileSystem {
    getFileForOpening(options?: { allowMultiple?: boolean; types?: string[]; initialLocation?: Entry }): Promise<Entry | Entry[] | null>;
    getFileForSaving(suggestedName: string, options?: { types?: string[] }): Promise<Entry | null>;
    getFolder(options?: { initialLocation?: Entry }): Promise<Entry | null>;
    getDataFolder(): Promise<Entry>;
    getTemporaryFolder(): Promise<Entry>;
  }
  interface SecureStorage {
    getItem(key: string): Promise<Uint8Array | null>;
    setItem(key: string, value: string | Uint8Array): Promise<void>;
    removeItem(key: string): Promise<void>;
  }
  export const storage: {
    localFileSystem: LocalFileSystem;
    secureStorage: SecureStorage;
    types: FileTypes;
  };
  export const shell: {
    openExternal(url: string, developerText?: string): Promise<string>;
    openPath(path: string, developerText?: string): Promise<string>;
  };
  export const host: {
    readonly name: string;
    readonly version: string;
    readonly uiLocale: string;
  };
  export const entrypoints: {
    setup(config: {
      plugin?: { create?(): void; destroy?(): void };
      panels?: Record<string, {
        create?(root: HTMLElement): void;
        show?(root: HTMLElement): void;
        hide?(): void;
        destroy?(): void;
        menuItems?: { id: string; label: string; enabled?: boolean; checked?: boolean }[];
        invokeMenu?(id: string): void;
      }>;
    }): void;
  };
  export const versions: { readonly uxp: string; readonly plugin: string };
}

declare module "os" {
  export function platform(): string;
  export function homedir(): string;
}

declare module "fs" {
  export function readFile(path: string, options?: { encoding?: string }): Promise<string | ArrayBuffer>;
  export function writeFile(path: string, data: string | ArrayBuffer | ArrayBufferView, options?: { encoding?: string; flag?: string }): Promise<number>;
  export function mkdir(path: string, options?: { recursive?: boolean }): Promise<number>;
  export function readdir(path: string): Promise<string[]>;
  export function lstat(path: string): Promise<{ isFile(): boolean; isDirectory(): boolean; size: number; mtimeMs?: number }>;
  export function unlink(path: string): Promise<void>;
  export function rename(from: string, to: string): Promise<void>;
}

/** Premiere's theme, on `document` (Adobe's CSS styling recipe). */
interface Document {
  theme?: {
    getCurrent(): string;
    onUpdated: { addListener(cb: (theme: string) => void): void };
  };
}
