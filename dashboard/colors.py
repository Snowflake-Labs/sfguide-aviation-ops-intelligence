"""
Aviation Operations Color Palette
Aviation-familiar intensity semantics for operational dashboards
"""

INTENSITY_GRADIENT = {
    'low_rgb': (79, 195, 247),
    'medium_rgb': (255, 193, 7),
    'high_rgb': (255, 87, 34),
    'extreme_rgb': (211, 47, 47),
    'critical_rgb': (136, 14, 79),
}

INTENSITY_COLOR_RANGE = [
    [79, 195, 247, 0],
    [79, 195, 247, 128],
    [255, 193, 7, 160],
    [255, 152, 0, 200],
    [255, 87, 34, 230],
    [211, 47, 47, 255],
]

def get_intensity_color_3point(normalized_value):
    """
    Returns RGB color for a value normalized between 0-1
    Uses 3-point gradient: teal → yellow → red
    """
    if normalized_value < 0.5:
        t = normalized_value * 2
        low = INTENSITY_GRADIENT['low_rgb']
        high = INTENSITY_GRADIENT['medium_rgb']
    else:
        t = (normalized_value - 0.5) * 2
        low = INTENSITY_GRADIENT['medium_rgb']
        high = INTENSITY_GRADIENT['extreme_rgb']
    
    r = int(low[0] + t * (high[0] - low[0]))
    g = int(low[1] + t * (high[1] - low[1]))
    b = int(low[2] + t * (high[2] - low[2]))
    return [r, g, b, 220]

def get_intensity_color_2point(normalized_value):
    """
    Returns RGB color for a value normalized between 0-1
    Uses 2-point gradient: teal → red
    """
    low = INTENSITY_GRADIENT['low_rgb']
    high = INTENSITY_GRADIENT['extreme_rgb']
    t = max(0.0, min(1.0, normalized_value))
    
    r = int(low[0] + t * (high[0] - low[0]))
    g = int(low[1] + t * (high[1] - low[1]))
    b = int(low[2] + t * (high[2] - low[2]))
    return [r, g, b, 220]

CROSSING_COLORS = {
    'normal': [255, 152, 0, 180],
    'elevated': [255, 87, 34, 200],
    'high': [244, 67, 54, 230],
    'critical': [211, 47, 47, 255],
}

BAR_COLORS = {
    'neutral': '#78909C',
    'default': '#4FC3F7',
    'highlighted': '#FF9800',
    'alert': '#F44336',
}

PLOTLY_INTENSITY_SCALE = [
    [0.0, '#4FC3F7'],
    [0.33, '#FFC107'],
    [0.67, '#FF5722'],
    [1.0, '#D32F2F'],
]
