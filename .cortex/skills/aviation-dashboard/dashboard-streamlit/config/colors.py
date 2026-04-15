"""
Color definitions, palettes, and color utility functions.
Aviation-standard intensity gradients and operational colors.
"""

# =============================================================================
# PRIMARY RGB DEFINITIONS
# =============================================================================

class RGB:
    """RGB color tuples (r, g, b)"""
    
    # Intensity gradient (aviation standard)
    LOW = (79, 195, 247)      # Teal - low activity/intensity
    MEDIUM = (255, 193, 7)    # Yellow - medium activity/intensity
    HIGH = (255, 87, 34)      # Orange - high activity/intensity
    EXTREME = (211, 47, 47)   # Red - extreme activity/intensity
    CRITICAL = (136, 14, 79)  # Dark red - critical threshold
    
    # Operational states
    NORMAL = (255, 152, 0)    # Orange - normal operations
    ELEVATED = (255, 87, 34)  # Deep orange - elevated alert
    ALERT = (244, 67, 54)     # Red - alert state
    
    # Neutral colors
    NEUTRAL = (120, 144, 156) # Blue-grey - neutral/inactive

# =============================================================================
# HEX COLOR PALETTE
# =============================================================================

class Hex:
    """Hex color codes for Altair/Plotly charts"""
    
    # Primary palette
    BLUE = '#4FC3F7'
    GREEN = '#66BB6A'
    RED = '#EF5350'
    ORANGE = '#FF9800'
    PURPLE = '#9C27B0'
    PINK = '#E91E63'
    CYAN = '#00BCD4'
    LIGHT_GREEN = '#43A047'
    DARK_ORANGE = '#F57C00'
    
    # Semantic colors
    DEFAULT = BLUE
    HIGHLIGHTED = ORANGE
    ALERT = '#F44336'
    NEUTRAL = '#78909C'
    
    # Use case specific
    DELAY = RED
    EARLY = LIGHT_GREEN
    DELAYED_FLIGHTS = DARK_ORANGE
    EARLY_MINUTES = GREEN
    UTILIZATION = BLUE
    FLIGHT = '#FF6B6B'

# =============================================================================
# RGBA ARRAYS (for PyDeck)
# =============================================================================

class RGBA:
    """RGBA arrays [r, g, b, alpha] for PyDeck layers"""
    
    @staticmethod
    def from_rgb(rgb, alpha=220):
        """Convert RGB tuple to RGBA list"""
        return [rgb[0], rgb[1], rgb[2], alpha]
    
    # Intensity gradient with varying alpha
    LOW_TRANSPARENT = [79, 195, 247, 0]
    LOW = [79, 195, 247, 128]
    MEDIUM = [255, 193, 7, 160]
    HIGH = [255, 152, 0, 200]
    EXTREME = [255, 87, 34, 230]
    CRITICAL = [211, 47, 47, 255]
    
    # Operational states
    NORMAL = [255, 152, 0, 180]
    ELEVATED = [255, 87, 34, 200]
    ALERT = [244, 67, 54, 230]
    ALERT_CRITICAL = [211, 47, 47, 255]

# =============================================================================
# COLOR GRADIENTS AND SCALES
# =============================================================================

# PyDeck intensity color range (for continuous mapping)
INTENSITY_COLOR_RANGE = [
    [79, 195, 247, 0],      # Teal (transparent)
    [79, 195, 247, 128],    # Teal (semi-transparent)
    [255, 193, 7, 160],     # Yellow
    [255, 152, 0, 200],     # Orange
    [255, 87, 34, 230],     # Deep orange
    [211, 47, 47, 255],     # Red (opaque)
]

# Plotly continuous color scale
PLOTLY_INTENSITY_SCALE = [
    [0.0, Hex.BLUE],        # Low
    [0.33, '#FFC107'],      # Medium
    [0.67, '#FF5722'],      # High
    [1.0, '#D32F2F'],       # Extreme
]

# =============================================================================
# COLOR CALCULATION FUNCTIONS
# =============================================================================

def get_intensity_color_3point(normalized_value):
    """
    Returns RGBA color for a value normalized between 0-1.
    Uses 3-point gradient: teal → yellow → red
    
    Args:
        normalized_value: Float between 0.0 and 1.0
    
    Returns:
        List [r, g, b, alpha] with values 0-255
    
    Example:
        >>> get_intensity_color_3point(0.0)   # Returns teal
        [79, 195, 247, 220]
        >>> get_intensity_color_3point(0.5)   # Returns yellow
        [255, 193, 7, 220]
        >>> get_intensity_color_3point(1.0)   # Returns red
        [211, 47, 47, 220]
    """
    if normalized_value < 0.5:
        # Interpolate between LOW (teal) and MEDIUM (yellow)
        t = normalized_value * 2
        low = RGB.LOW
        high = RGB.MEDIUM
    else:
        # Interpolate between MEDIUM (yellow) and EXTREME (red)
        t = (normalized_value - 0.5) * 2
        low = RGB.MEDIUM
        high = RGB.EXTREME
    
    r = int(low[0] + t * (high[0] - low[0]))
    g = int(low[1] + t * (high[1] - low[1]))
    b = int(low[2] + t * (high[2] - low[2]))
    return [r, g, b, 220]


def get_intensity_color_2point(normalized_value):
    """
    Returns RGBA color for a value normalized between 0-1.
    Uses 2-point gradient: teal → red (no yellow intermediate)
    
    Args:
        normalized_value: Float between 0.0 and 1.0
    
    Returns:
        List [r, g, b, alpha] with values 0-255
    
    Example:
        >>> get_intensity_color_2point(0.0)   # Returns teal
        [79, 195, 247, 220]
        >>> get_intensity_color_2point(1.0)   # Returns red
        [211, 47, 47, 220]
    """
    low = RGB.LOW
    high = RGB.EXTREME
    t = max(0.0, min(1.0, normalized_value))
    
    r = int(low[0] + t * (high[0] - low[0]))
    g = int(low[1] + t * (high[1] - low[1]))
    b = int(low[2] + t * (high[2] - low[2]))
    return [r, g, b, 220]


def rgb_to_hex(rgb):
    """
    Convert RGB tuple to hex color code.
    
    Args:
        rgb: Tuple (r, g, b) with values 0-255
    
    Returns:
        String hex color code like '#4FC3F7'
    
    Example:
        >>> rgb_to_hex((79, 195, 247))
        '#4FC3F7'
    """
    return '#{:02x}{:02x}{:02x}'.format(rgb[0], rgb[1], rgb[2])


def hex_to_rgb(hex_color):
    """
    Convert hex color code to RGB tuple.
    
    Args:
        hex_color: String like '#4FC3F7' or '4FC3F7'
    
    Returns:
        Tuple (r, g, b) with values 0-255
    
    Example:
        >>> hex_to_rgb('#4FC3F7')
        (79, 195, 247)
    """
    hex_color = hex_color.lstrip('#')
    return tuple(int(hex_color[i:i+2], 16) for i in (0, 2, 4))

# =============================================================================
# LEGACY COMPATIBILITY DICTIONARIES
# =============================================================================
# These allow old code to continue working during migration

# Legacy COLORS dict (from chart_config.py)
COLORS = {
    # Primary colors
    'blue': Hex.BLUE,
    'green': Hex.GREEN,
    'red': Hex.RED,
    'orange': Hex.ORANGE,
    'purple': Hex.PURPLE,
    'pink': Hex.PINK,
    'cyan': Hex.CYAN,
    'light_green': Hex.LIGHT_GREEN,
    'dark_orange': Hex.DARK_ORANGE,
    'red_accent': '#FF6B6B',
    
    # Specific use cases
    'delay': Hex.DELAY,
    'early': Hex.EARLY,
    'delayed_flights': Hex.DELAYED_FLIGHTS,
    'early_minutes': Hex.EARLY_MINUTES,
    'default': Hex.DEFAULT,
    'utilization': Hex.UTILIZATION,
    'flight': Hex.FLIGHT,
}

# Legacy INTENSITY_GRADIENT dict (from colors.py)
INTENSITY_GRADIENT = {
    'low_rgb': RGB.LOW,
    'medium_rgb': RGB.MEDIUM,
    'high_rgb': RGB.HIGH,
    'extreme_rgb': RGB.EXTREME,
    'critical_rgb': RGB.CRITICAL,
}

# Legacy CROSSING_COLORS dict (from colors.py)
CROSSING_COLORS = {
    'normal': RGBA.NORMAL,
    'elevated': RGBA.ELEVATED,
    'high': RGBA.ALERT,
    'critical': RGBA.ALERT_CRITICAL,
}

# Legacy BAR_COLORS dict (from colors.py)
BAR_COLORS = {
    'neutral': Hex.NEUTRAL,
    'default': Hex.DEFAULT,
    'highlighted': Hex.HIGHLIGHTED,
    'alert': Hex.ALERT,
}
