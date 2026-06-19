/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Base URL of the local privacy_box API. Defaults to http://localhost:10000. */
  readonly VITE_PRIVACY_BOX_API?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
