# openpult enclosure

Parametric 3D-printable case for the openpult IR blaster: a low box with a battery bay, a board bay, a slide
switch, a reset button and a hinged nose that aims the IR LED at the TV's sensor. Written in Python with
[manifold3d](https://github.com/elalish/manifold); every size is in [`params.py`](params.py).

- [Printing and assembly](../docs/enclosure/printing.md): what to print, orientation, settings, hardware, assembly.
- [Customizing](../docs/enclosure/customizing.md): parameters, board and battery presets, adding your own board.

Ready STL files and previews are in `out/<variant>/` (`default`: SuperMini/nice!nano + 3×AA).

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python build.py          # STL files → out/<variant>/
.venv/bin/python check.py          # geometry checks for every variant
.venv/bin/python render.py         # PNG previews
.venv/bin/python -m pytest tests
```

| File | Contents |
|---|---|
| `params.py` | all dimensions, board and power presets, variants |
| `parts.py` | tray, lid and nose geometry; phantom solids of the components |
| `build.py` | writes the STL files |
| `check.py` | fit, clearance, beam, balance and printability checks |
| `render.py` | matplotlib previews |
| `tests/` | pytest suite |
