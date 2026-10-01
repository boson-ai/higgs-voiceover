// What CEP puts on `window` (the CEP 9–12 HTML Extension Cookbook). Used
// directly rather than through Adobe's CSInterface.js, which only wraps them.

interface CepBridge {
  evalScript(script: string, callback?: (result: string) => void): void;
  getHostEnvironment(): string;
  addEventListener(type: string, listener: (event: unknown) => void): void;
  closeExtension(): void;
}

interface CepFileResult { err: number; data: string | string[] }

interface Window {
  __adobe_cep__?: CepBridge;
  cep?: {
    fs: {
      showOpenDialogEx(allowMultiple: boolean, chooseDirectory: boolean, title: string, initialPath?: string, fileTypes?: string[], friendlyName?: string, prompt?: string): CepFileResult;
      showSaveDialogEx(title: string, initialPath?: string, fileTypes?: string[], defaultName?: string, friendlyName?: string, prompt?: string, nameFieldLabel?: string): CepFileResult;
    };
    util: { openURLInDefaultBrowser(url: string): number };
  };
}
