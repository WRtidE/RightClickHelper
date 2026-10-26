#!/usr/bin/env python3
"""Verify blank OOXML resources or files created through Finder.
Usage: python3 scripts/verify_office_templates.py [file.docx file.pptx file.xlsx ...]
Uses the same developer-only libraries as generate_office_templates.py.
"""
from pathlib import Path
from posixpath import dirname, normpath
import sys
from urllib.parse import unquote
from lxml import etree as ET
from zipfile import ZipFile

from docx import Document
from openpyxl import load_workbook
from pptx import Presentation

ROOT = Path(__file__).resolve().parents[1]
MAIN_PARTS = {".docx": "word/document.xml", ".pptx": "ppt/presentation.xml", ".xlsx": "xl/workbook.xml"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(path):
    with ZipFile(path) as archive:
        require(archive.testzip() is None, "ZIP checksum failure")
        names = set(archive.namelist())
        require({"[Content_Types].xml", "_rels/.rels", MAIN_PARTS[path.suffix]} <= names, "Missing package parts")
        require(not any("vbaproject" in name.lower() for name in names), "Unexpected macro")
        for name in names:
            if name.endswith((".xml", ".rels")):
                tree = ET.fromstring(archive.read(name))
                for element in tree.iter():
                    qualified_type = element.get("{http://www.w3.org/2001/XMLSchema-instance}type", "")
                    if ":" in qualified_type:
                        require(qualified_type.split(":", 1)[0] in element.nsmap,
                                f"Unbound xsi:type namespace in {name}")
                if name.endswith(".rels"):
                    base = "" if name == "_rels/.rels" else dirname(dirname(name))
                    for relation in tree:
                        require(relation.get("TargetMode") != "External", "Unexpected external link")
                        target = unquote(relation.attrib["Target"])
                        resolved = target.lstrip("/") if target.startswith("/") else normpath(base + "/" + target).lstrip("/")
                        require(resolved in names, f"Broken relationship: {name} -> {target}")
        types = archive.read("[Content_Types].xml")
        require(b"macroEnabled" not in types, "Unexpected macro-enabled type")
        if path.suffix == ".docx":
            ns = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
            settings = ET.fromstring(archive.read("word/settings.xml"))
            require(any(s.get(ns + "name") == "compatibilityMode" and s.get(ns + "val") == "15"
                        for s in settings.iter(ns + "compatSetting")), "Legacy Word compatibility mode")
    if path.suffix == ".docx":
        document = Document(path)
        require(len(document.paragraphs) == 1 and document.paragraphs[0].text == "", "Word is not blank")
        require(not document.tables and not document.inline_shapes, "Unexpected Word content")
        description = "1 empty paragraph"
    elif path.suffix == ".pptx":
        slides = Presentation(path)
        require(len(slides.slides) == 1 and len(slides.slides[0].shapes) == 0, "PPTX is not one blank slide")
        require(abs(slides.slide_width / slides.slide_height - 16 / 9) < 0.001, "Slide ratio is not 16:9")
        description = "1 blank 16:9 slide"
    else:
        workbook = load_workbook(path)
        require(workbook.sheetnames == ["工作表1"], "Unexpected worksheets")
        require(all(cell.value is None for row in workbook.active for cell in row), "Workbook is not blank")
        workbook.close()
        description = "1 empty worksheet"
    print(f"PASS {path.name}: {path.stat().st_size} bytes; {description}; valid ZIP/XML/relationships; no macros/external links")


if __name__ == "__main__":
    paths = [Path(arg) for arg in sys.argv[1:]] or sorted((ROOT / "Shared/Resources").glob("blank.*"))
    for path in paths:
        verify(path)
