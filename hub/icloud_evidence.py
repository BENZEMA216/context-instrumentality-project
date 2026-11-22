"""Evidence upgrades for the recording bridge's directory-only observations."""
import json

from .imports import stable_id

CONNECTOR = "record-for-agent.icloud"
FULL = "committed_manifest_and_audio_entry"
EARLY = "commit_and_manifest_verified"


def downgrade_legacy_audio(store, conn):
    # Before leaf observations were versioned, even an explicit true flag could
    # have been inferred from an unmaterialized *parent*. Recheck from the Mac.
    # Restrict adoption to bridge-owned revisions or pristine pre-tracking rows.
    after = ""
    while True:
        rows = conn.execute("""SELECT r.id,r.event,r.revision,b.revision AS managed
            FROM raw_events r LEFT JOIN icloud_bridge_revisions b ON b.raw_id=r.id
            WHERE r.id>? AND r.source='voice' AND r.connector=? AND r.tier='local_only'
              AND (r.revision=b.revision OR (b.revision IS NULL AND (r.revision=1 OR
                   (r.revision=2 AND json_type(r.event,'$.content.transcript_commit_observed')='true'
                    AND json_type(r.event,'$.provenance.audio_entry_observed') IS NULL))))
              AND json_extract(r.event,'$.kind')='cloud_audio_commit'
              AND json_extract(r.event,'$.provenance.evidence')=?
              AND json_extract(r.event,'$.provenance.audio_leaf_observation_version') IS NOT 1
            ORDER BY r.id LIMIT 128""", (after, CONNECTOR, FULL)).fetchall()
        if not rows:
            return
        for row in rows:
            event = json.loads(row["event"])
            proof = event["provenance"]
            if row["managed"] is None:
                library, original = proof.get("library_id"), proof.get("original_id")
                if not isinstance(library, str) or not isinstance(original, str):
                    continue
                if (event["id"] != stable_id(CONNECTOR, library, original)
                        or proof["source_id"] != library + "/" + original
                        or set(event.get("content", {})) != {"transcript_commit_observed"}
                        or set(event.get("context", {})) != {"sessionID", "sequence", "sampleRate", "frameCount", "byteCount"}):
                    continue
            proof.update(evidence=EARLY, audio_entry_observed=False)
            revision = store._put_raw(conn, event, row["revision"])["revision"]
            if row["managed"] is not None or row["revision"] == 1:
                conn.execute("""INSERT INTO icloud_bridge_revisions VALUES(?,?)
                    ON CONFLICT(raw_id) DO UPDATE SET revision=excluded.revision""", (row["id"], revision))
            # The pre-tracking importer could enrich the transcript flag once.
            # For that revision, reclaim ownership only after an exact fresh match.
            # The revision trigger cleared any former projection. Existing grants
            # become visible on the next scoped commit + manifest verification.
        after = rows[-1]["id"]
