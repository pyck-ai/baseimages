// Example RFW (Remote Flutter Widgets) file
// This demonstrates the basic syntax and structure

import core.widgets;

// Simple example widget with a button
widget ExampleButton = Container(
    child: Column(
        children: [
          Text(text: "Hello, Flutter!"),
          ElevatedButton(
            text: "Click Me",
            onPressed: event "button_clicked" { }
          ),
        ]
    )
);

// Example form widget
widget ExampleForm = Container(
    padding: [16.0],
    child: ListView(
        children: [
          Text(text: "Example Form", style: { fontSize: 24.0 }),
          TextField(
            decoration: {
              labelText: "Enter your name",
              hintText: "John Doe"
            }
          ),
          SizedBox(height: 16.0),
          Row(
            mainAxisAlignment: "end",
            children: [
              OutlinedButton(
                text: "Cancel",
                onPressed: event "cancel" { }
              ),
              SizedBox(width: 8.0),
              ElevatedButton(
                text: "Submit",
                onPressed: event "submit" { }
              ),
            ]
          ),
        ]
    )
);
