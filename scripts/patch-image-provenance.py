import pathlib
import sys

checkout = pathlib.Path(sys.argv[1])

def replace(name, old, new):
    path = checkout / name
    text = path.read_text()
    if new in text:
        return
    if old not in text:
        raise SystemExit('Image provenance patch does not apply: ' + name)
    path.write_text(text.replace(old, new))

p = 'Sources/socktainer/Routes/Images/ImageInspectRoute.swift'
replace(p, 'RepoDigests: repoDigestReference(name: image.reference, digest: selectedDescriptor?.digest).map { [$0] } ?? [],', 'RepoDigests: GUIImageProvenance.repoDigests(image),')
replace(p, 'Parent: "",', 'Parent: await GUIImageProvenance.parent(of: image, platform: selectedVariant.platform),')
p = 'Sources/socktainer/Routes/Images/ImageListRoute.swift'
replace(p, 'includeDigests && image.reference.contains("@sha256:") ? [image.reference] : []', 'includeDigests ? GUIImageProvenance.repoDigests(image) : []')
p = 'Sources/socktainer/Clients/ClientImageService.swift'
replace(p, 'continuation.yield(.message("Image digest: \\(image.digest)"))', 'try await GUIImageProvenance.recordPull(image)\n                    continuation.yield(.message("Image digest: \\(image.digest)"))')
replace(p, 'continuation.yield(.message("Image digest: \\(fallbackImage.digest)"))', 'try await GUIImageProvenance.recordPull(fallbackImage)\n                            continuation.yield(.message("Image digest: \\(fallbackImage.digest)"))')

for route in ['ImageInspectRoute', 'ImageHistoryRoute']:
    replace('Sources/socktainer/Routes/Images/' + route + '.swift', 'ClientImage.get(reference: refOrId, containerSystemConfig: systemConfig)', 'GUIImageProvenance.resolve(refOrId, systemConfig: systemConfig)')
