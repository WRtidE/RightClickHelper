#!/usr/bin/env python3
"""Rebuild bundled, macro-free OOXML blanks. Developer-only dependencies:
python-docx==1.2.0 python-pptx==1.0.2 openpyxl==3.1.5
The shipped app only copies these resources; it never runs Python or Office.
"""
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from docx import Document
from docx.oxml.ns import qn
from openpyxl import Workbook
from pptx import Presentation
from pptx.util import Inches

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "Shared" / "Resources"
STAMP = datetime(2000, 1, 1, tzinfo=timezone.utc)


def clear_properties(properties):
    for field in ("author", "last_modified_by", "title", "subject", "keywords",
                  "comments", "category", "identifier", "language"):
        setattr(properties, field, "")
    properties.created = STAMP
    properties.modified = STAMP
    properties.revision = 1


def save_template(document, extension):
    raw = BytesIO()
    document.save(raw)
    # Stable ZIP metadata makes rebuilding and reviewing resources repeatable.
    with ZipFile(raw) as source, ZipFile(DEST / f"blank.{extension}", "w", ZIP_DEFLATED) as output:
        for name in sorted(source.namelist()):
            data = source.read(name)
            if extension == "xlsx" and name == "docProps/core.xml":
                # openpyxl overwrites modified time during save.
                # Preserve prefixes used inside xsi:type attribute values.
                from lxml import etree as ET
                tree = ET.fromstring(data)
                for field in ("created", "modified"):
                    tree.find(f"{{http://purl.org/dc/terms/}}{field}").text = "2000-01-01T00:00:00Z"
                data = ET.tostring(tree, encoding="utf-8", xml_declaration=True)
            info = ZipInfo(name, (2000, 1, 1, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o600 << 16
            output.writestr(info, data)
    print(f"Generated {DEST / f'blank.{extension}'}")


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    word = Document()
    word.add_paragraph()
    # python-docx's starter uses Word 2010 compatibility mode. Use the modern
    # default (15) so Word opens a new document without a compatibility banner.
    # https://learn.microsoft.com/en-us/office/vba/api/word.wdcompatibilitymode
    for setting in word.settings.element.findall(".//" + qn("w:compatSetting")):
        if setting.get(qn("w:name")) == "compatibilityMode":
            setting.set(qn("w:val"), "15")
    clear_properties(word.core_properties)
    save_template(word, "docx")

    slides = Presentation()
    slides.slide_width = Inches(13.333333)
    slides.slide_height = Inches(7.5)
    slides.slides.add_slide(slides.slide_layouts[6])  # Blank; no placeholders.
    clear_properties(slides.core_properties)
    save_template(slides, "pptx")

    workbook = Workbook()
    workbook.active.title = "工作表1"
    workbook.properties.creator = ""
    workbook.properties.lastModifiedBy = ""
    workbook.properties.created = STAMP
    workbook.properties.modified = STAMP
    save_template(workbook, "xlsx")


if __name__ == "__main__":
    main()
