"""python flow/harden/render.py GDS PNG [px] : render a GDS layout to PNG with the KLayout Python module (headless)."""
import sys
import klayout.lay as lay
gds, png = sys.argv[1], sys.argv[2]
px = int(sys.argv[3]) if len(sys.argv) > 3 else 2048
v = lay.LayoutView()
v.load_layout(gds)
v.max_hier()
v.set_config('background-color', '#0a0c10')
v.set_config('grid-visible', 'false')
v.set_config('text-visible', 'false')
v.zoom_fit()
v.save_image(png, px, px)
print('rendered', png)
