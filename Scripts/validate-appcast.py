"""Fail closed if the release feed does not match the signed local app."""
import pathlib, plistlib, sys, xml.etree.ElementTree as ET
feed, app = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(feed).findall("./channel/item")
# generate_appcast may discover the separately shipped installer too: remove it.
root = ET.parse(feed)
channel = root.find("channel")
for item in list(channel.findall("item")):
    enclosure = item.find("enclosure")
    if enclosure is not None and not enclosure.attrib.get("url", "").endswith(".zip"):
        channel.remove(item)
items = channel.findall("item")
assert len(items) == 1, "Expected exactly one App zip in this release feed"
enclosure = items[0].find("enclosure")
assert enclosure is not None
assert enclosure.attrib.get(ns + "edSignature"), "Missing EdDSA signature"
version = items[0].findtext(ns + "version") or enclosure.attrib.get(ns + "version")
assert version == info["CFBundleVersion"], "Build version mismatch"
assert enclosure.attrib["url"].startswith("https://github.com/Cooper-Han/RouteDuo/releases/download/"), "Unexpected download host"
ET.register_namespace("sparkle", "http://www.andymatuschak.org/xml-namespaces/sparkle")
root.write(feed, encoding="utf-8", xml_declaration=True)
print("Feed validated: signed App zip, expected version and GitHub URL")
