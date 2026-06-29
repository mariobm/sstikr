# R2 Sticker Images

R2 is the image origin for unlocked sticker artwork. The local extraction
artifacts and PDFs were removed after upload; the iOS catalog JSON and Supabase
seed SQL now store the stable object keys and public image URLs.

Sticker artwork is stored as AVIF. The original JPG and full-size AVIF objects
may still exist in the bucket for rollback, but app and backend catalog
references should point at the half-dimension `@0.5x.avif` keys.

The half-size variants were generated from 994 full-size AVIF objects. They are
about 9.6 MB total, down from about 25.5 MB for the full-size AVIF set.

The current bucket name is `world-cup-stickers`, and object keys are stable:

```text
stickers-new/00@0.5x.avif
stickers-new/MEX/MEX-1@0.5x.avif
stickers-new/FWC/FWC-2@0.5x.avif
stickers-new/CC/CC-1@0.5x.avif
```

Public base URL:

```text
https://pub-3b9d1ae073c04cb09a9be9e70f160f7b.r2.dev
```

## Re-uploading

To re-upload from scratch, restore/regenerate the extracted sticker images,
convert them to AVIF, create the `@0.5x` variants, then run
`scripts/generate_remote_catalog.py` to recreate the upload manifest and
`scripts/upload_stickers_new_to_r2.py` to push objects to R2.
