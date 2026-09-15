# Canonical marketplace projection ownership

The portable manifest, capability declaration, and marketplace catalog are
the release inputs. Claude Code and Codex manifests and catalogs are generated
projections, so manually changing either host's copy creates silent drift that
the other host cannot inherit. The canonical marketplace CLI owns projection
generation, validation, and version bumps; it deliberately performs no VCS
action, leaving reviewed commits and pushes under the maintainer's control.
