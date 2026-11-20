// ─── `daemon migrate` on macOS (shared CLI seam; #31 moves a pre-cb33 Windows home) ───
// On macOS there is no separate step: `daemon install` (setup-daemon.sh) installs the service home and
// migrate-daemon-config.sh brings a kept older home's config.toml to the cb33 layout, same device key.
// So the command answers "skipped" with what to run instead.

export interface MigrateOptions {
  /** the new daemon binary */
  dvpnd: string;
  /** Windows only: the old daemon the installer saved */
  legacyDvpnd?: string;
  programData?: string;
}

export type MigrateResult =
  | { status: 'skipped'; reason: string }
  | { status: 'migrated'; from: string; to: string; device?: string; log: string[] }
  | { status: 'failed'; step: string; error: string; log: string[] };

export async function runHomeMigration(_opts: MigrateOptions): Promise<MigrateResult> {
  return { status: 'skipped', reason: 'not needed on macOS: "daemon install --yes" moves an older service home to the new layout itself' };
}
