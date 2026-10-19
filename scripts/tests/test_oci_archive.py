from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("validate_oci", ROOT / "scripts" / "validate-oci-archive.py")
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class OCIArchiveTests(unittest.TestCase):
    def archive(
        self, root: Path, *, wrong_attestation_reference: bool = False,
        extra_platform: bool = False, unreferenced_blob: bool = False,
        extra_predicate: bool = False,
    ) -> tuple[Path, str, str]:
        config = b'{"architecture":"amd64","os":"linux"}'
        layer = b"reviewed-layer"
        config_hash = hashlib.sha256(config).hexdigest()
        layer_hash = hashlib.sha256(layer).hexdigest()
        manifest = json.dumps({
            "schemaVersion": 2,
            "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": f"sha256:{config_hash}", "size": len(config)},
            "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": f"sha256:{layer_hash}", "size": len(layer)}],
        }, sort_keys=True, separators=(",", ":")).encode()
        manifest_hash = hashlib.sha256(manifest).hexdigest()
        attestation_config = b"{}"
        attestation_config_hash = hashlib.sha256(attestation_config).hexdigest()

        def statement(predicate_type: str, predicate: dict) -> tuple[bytes, str]:
            contents = json.dumps({
                "_type": "https://in-toto.io/Statement/v0.1",
                "subject": [{"name": "locallingo/backend", "digest": {"sha256": manifest_hash}}],
                "predicateType": predicate_type, "predicate": predicate,
            }, sort_keys=True, separators=(",", ":")).encode()
            return contents, hashlib.sha256(contents).hexdigest()

        provenance, provenance_hash = statement(
            "https://slsa.dev/provenance/v0.2", {"builder": {}, "buildType": "unit-test"}
        )
        sbom, sbom_hash = statement("https://spdx.dev/Document", {"spdxVersion": "SPDX-2.3"})
        attestation_layers = [
            {
                "mediaType": "application/vnd.in-toto+json", "digest": f"sha256:{provenance_hash}",
                "size": len(provenance),
                "annotations": {"in-toto.io/predicate-type": "https://slsa.dev/provenance/v0.2"},
            },
            {
                "mediaType": "application/vnd.in-toto+json", "digest": f"sha256:{sbom_hash}",
                "size": len(sbom),
                "annotations": {"in-toto.io/predicate-type": "https://spdx.dev/Document"},
            },
        ]
        extra_statement = b""
        extra_statement_hash = ""
        if extra_predicate:
            extra_statement, extra_statement_hash = statement("https://example.invalid/extra", {})
            attestation_layers.append({
                "mediaType": "application/vnd.in-toto+json", "digest": f"sha256:{extra_statement_hash}",
                "size": len(extra_statement),
                "annotations": {"in-toto.io/predicate-type": "https://example.invalid/extra"},
            })
        attestation_manifest = json.dumps({
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {
                "mediaType": "application/vnd.oci.image.config.v1+json",
                "digest": f"sha256:{attestation_config_hash}", "size": len(attestation_config),
            },
            "layers": attestation_layers,
        }, sort_keys=True, separators=(",", ":")).encode()
        attestation_manifest_hash = hashlib.sha256(attestation_manifest).hexdigest()
        descriptors = [
            {"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": f"sha256:{manifest_hash}", "size": len(manifest), "platform": {"architecture": "amd64", "os": "linux"}},
            {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": f"sha256:{attestation_manifest_hash}", "size": len(attestation_manifest),
                "platform": {"architecture": "unknown", "os": "unknown"},
                "annotations": {
                    "vnd.docker.reference.digest": "sha256:" + ("0" * 64 if wrong_attestation_reference else manifest_hash),
                    "vnd.docker.reference.type": "attestation-manifest",
                },
            },
        ]
        extra_manifest = b'{"schemaVersion":2,"annotations":{"unexpected":true}}'
        extra_manifest_hash = hashlib.sha256(extra_manifest).hexdigest()
        if extra_platform:
            descriptors.append({
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": f"sha256:{extra_manifest_hash}", "size": len(extra_manifest),
                "platform": {"architecture": "arm64", "os": "linux"},
            })
        index = json.dumps({
            "schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": descriptors,
        }, sort_keys=True, separators=(",", ":")).encode()
        index_hash = hashlib.sha256(index).hexdigest()
        files = {
            "oci-layout": b'{"imageLayoutVersion":"1.0.0"}',
            "index.json": index,
            f"blobs/sha256/{manifest_hash}": manifest,
            f"blobs/sha256/{config_hash}": config,
            f"blobs/sha256/{layer_hash}": layer,
            f"blobs/sha256/{attestation_manifest_hash}": attestation_manifest,
            f"blobs/sha256/{attestation_config_hash}": attestation_config,
            f"blobs/sha256/{provenance_hash}": provenance,
            f"blobs/sha256/{sbom_hash}": sbom,
        }
        if extra_platform:
            files[f"blobs/sha256/{extra_manifest_hash}"] = extra_manifest
        if unreferenced_blob:
            orphan = b"unreachable"
            files[f"blobs/sha256/{hashlib.sha256(orphan).hexdigest()}"] = orphan
        if extra_predicate:
            files[f"blobs/sha256/{extra_statement_hash}"] = extra_statement
        path = root / "image.oci"
        with tarfile.open(path, "w") as archive:
            for name, contents in files.items():
                info = tarfile.TarInfo(name)
                info.size = len(contents)
                archive.addfile(info, io.BytesIO(contents))
        return path, f"sha256:{index_hash}", f"sha256:{manifest_hash}"

    def test_real_oci_subject_matches_expected_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, index_digest, runnable_digest = self.archive(Path(temporary))
            self.assertEqual(MODULE.validate_archive(archive, index_digest), runnable_digest)

    def test_metadata_digest_cannot_override_archive_subject(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, _, _ = self.archive(Path(temporary))
            with self.assertRaisesRegex(ValueError, "root index digest does not match BuildKit metadata"):
                MODULE.validate_archive(archive, "sha256:" + "0" * 64)

    def test_attestation_must_reference_runnable_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, digest, _ = self.archive(Path(temporary), wrong_attestation_reference=True)
            with self.assertRaisesRegex(ValueError, "does not reference the runnable manifest"):
                MODULE.validate_archive(archive, digest)

    def test_extra_runnable_platform_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, digest, _ = self.archive(Path(temporary), extra_platform=True)
            with self.assertRaisesRegex(ValueError, "unexpected runnable or unknown platform"):
                MODULE.validate_archive(archive, digest)

    def test_unreferenced_blob_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, digest, _ = self.archive(Path(temporary), unreferenced_blob=True)
            with self.assertRaisesRegex(ValueError, "unreferenced blobs"):
                MODULE.validate_archive(archive, digest)

    def test_unknown_attestation_predicate_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, digest, _ = self.archive(Path(temporary), extra_predicate=True)
            with self.assertRaisesRegex(ValueError, "exactly the reviewed SPDX and SLSA"):
                MODULE.validate_archive(archive, digest)


if __name__ == "__main__":
    unittest.main()
