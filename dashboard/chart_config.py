"""
Centralized configuration for all Altair chart styling across the dashboard.
Edit these values to change the appearance of all bar charts consistently.
"""

# Bar Chart Sizing
BAR_CONFIG = {
    'horizontal': {
        'step': 20,           # Pixels per bar for horizontal bars
        'size': 15,           # Bar thickness in pixels
        'label_limit': 200    # Max width for Y-axis labels
    },
    'vertical': {
        'step': 50,           # Pixels per bar for vertical bars
        'size': 40,           # Bar thickness in pixels
    },
    'horizontal_compact': {
        'step': 20,           # For charts with many items (now same as horizontal)
        'size': 15,           # Bar thickness (now same as horizontal)
        'label_limit': 200
    },
    'horizontal_large': {
        'step': 20,           # For charts with few items (now same as horizontal)
        'size': 15,           # Bar thickness (now same as horizontal)
        'label_limit': 200
    }
}

# Chart Colors
COLORS = {
    # Primary colors
    'blue': '#4FC3F7',
    'green': '#66BB6A',
    'red': '#EF5350',
    'orange': '#FF9800',
    'purple': '#9C27B0',
    'pink': '#E91E63',
    'cyan': '#00BCD4',
    'light_green': '#43A047',
    'dark_orange': '#F57C00',
    'red_accent': '#FF6B6B',
    
    # Specific use cases
    'delay': '#EF5350',
    'early': '#43A047',
    'delayed_flights': '#F57C00',
    'early_minutes': '#66BB6A',
    'default': '#4FC3F7',
    'utilization': '#4FC3F7',
    'flight': '#FF6B6B',
}

# Heatmap Colors
HEATMAP_COLORS = {
    'scheme': 'teals',
    'diverging': 'redyellowgreen',
    'sequential': 'blues'
}

# Common axis configurations
AXIS_CONFIG = {
    'label_limit_short': 150,
    'label_limit_medium': 200,
    'label_limit_long': 300
}

# Tooltip formatting
TOOLTIP_FORMAT = {
    'integer': ',.0f',
    'decimal_1': ',.1f',
    'decimal_2': ',.2f',
    'percent': '.1%'
}
