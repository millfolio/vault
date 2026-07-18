/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Base URL of the local enclave API. Defaults to http://localhost:10000. */
  readonly VITE_ENCLAVE_API?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
