#!/bin/sh -e
#  copy-baysyl-recs.sh
#  Trio
#
#  Optional, display only: copies Trio/Resources/BaysylRecs.json into the app bundle when the file
#  exists, for the "Baysyl recommends" screen. The file is not in the repository (it is gitignored);
#  a private build writes it before building. When it is absent this does nothing, apart from
#  removing a copy left in the bundle by an earlier build.

source_path="${SRCROOT}/Trio/Resources/BaysylRecs.json"
destination_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
destination_path="${destination_dir}/BaysylRecs.json"

if [ -z "${TARGET_BUILD_DIR}" ] || [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH}" ]; then
    echo "copy-baysyl-recs: build paths are not set; nothing done."
    exit 0
fi

if [ -s "${source_path}" ]; then
    mkdir -p "${destination_dir}"
    cp "${source_path}" "${destination_path}"
    echo "copy-baysyl-recs: bundled BaysylRecs.json."
else
    rm -f "${destination_path}"
    echo "copy-baysyl-recs: no BaysylRecs.json; none bundled."
fi
