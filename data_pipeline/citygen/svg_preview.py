"""Preview SVG (hillshade + vias + edificios). Solo herramienta de desarrollo."""


def _append_hillshade(parts, terrain: dict):
    heights = terrain["heights"]
    nx, nz = terrain["nx"], terrain["nz"]
    cell = terrain["cell_size"]
    origin_x, origin_z = terrain["origin_x"], terrain["origin_z"]
    max_h = max(heights) if heights else 0.0
    for j in range(nz - 1):
        for i in range(nx - 1):
            h_avg = (
                heights[j * nx + i]
                + heights[j * nx + i + 1]
                + heights[(j + 1) * nx + i]
                + heights[(j + 1) * nx + i + 1]
            ) / 4.0
            gray = int(round(255 * (h_avg / max_h))) if max_h > 0 else 180
            gray = max(0, min(255, gray))
            x = origin_x + i * cell
            z = origin_z + j * cell
            parts.append(
                f'<rect x="{x:.2f}" y="{z:.2f}" width="{cell:.2f}" height="{cell:.2f}" '
                f'fill="rgb({gray},{gray},{gray})" opacity="0.5" />'
            )


def generate_svg(roads, buildings, terrain, path):
    all_x = []
    all_z = []
    for road in roads:
        for x, z in road["points"]:
            all_x.append(x)
            all_z.append(z)
    for b in buildings:
        for x, z in b["footprint"]:
            all_x.append(x)
            all_z.append(z)
    # Incluir la extension de la grilla de terreno para que el hillshade no se recorte.
    all_x.append(terrain["origin_x"])
    all_x.append(terrain["origin_x"] + (terrain["nx"] - 1) * terrain["cell_size"])
    all_z.append(terrain["origin_z"])
    all_z.append(terrain["origin_z"] + (terrain["nz"] - 1) * terrain["cell_size"])

    if not all_x:
        print("Sin datos para preview.svg")
        return

    margin = 10.0
    min_x, max_x = min(all_x) - margin, max(all_x) + margin
    min_z, max_z = min(all_z) - margin, max(all_z) + margin
    width = max_x - min_x
    height = max_z - min_z

    # La formula de proyeccion ya deja z negativo hacia el norte, asi que
    # usar z directamente como coordenada svg-y coloca el norte arriba.
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{min_x:.2f} {min_z:.2f} {width:.2f} {height:.2f}">',
        f'<rect x="{min_x:.2f}" y="{min_z:.2f}" width="{width:.2f}" height="{height:.2f}" fill="#f0f0f0" />',
    ]

    _append_hillshade(parts, terrain)

    for b in buildings:
        pts = " ".join(f"{x:.2f},{z:.2f}" for x, z in b["footprint"])
        parts.append(f'<polygon points="{pts}" fill="#999999" stroke="none" />')

    for road in roads:
        pts = " ".join(f"{x:.2f},{z:.2f}" for x, z in road["points"])
        stroke_width = max(road["width"] * 0.5, 0.5)
        parts.append(
            f'<polyline points="{pts}" fill="none" stroke="#000000" '
            f'stroke-width="{stroke_width:.2f}" stroke-linecap="round" stroke-linejoin="round" />'
        )

    parts.append("</svg>")

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))
    print(f"preview.svg escrito: {path}")
