# Virtual Stop Cascade EA Framework (MQL5)

## The Core Idea
In real trading, there is often a specific setup that feels intuitive but cannot be easily explained through words or rigid formulas. 

I managed to solve this by creating a **Virtual Machine** that trades the "supposed" setup virtually until a certain pre-defined point. Only when that point is reached does the "Real Machine" trigger and begin executing actual trades. 

This single architectural modification made the EA not only more efficient but also paved the way for other strategies to apply the same Virtual-to-Real approach and optimize their execution.

## 🏗️ Technical Architecture

*   **Virtual State Machine:** The EA operates in `PHASE_VIRTUAL`, `PHASE_ARMED`, and `PHASE_REAL`. It tracks virtual stop-losses and Take-Profits internally without sending orders to the broker.
*   **Incremental Cascade System:** If a virtual stop is hit, the system mathematically calculates the next leg, flipping direction and dynamically adjusting Take-Profit ratios based on the number of consecutive stops.
*   **Pluggable Signal Layer:** The entry logic is decoupled from the execution engine. (Note: The proprietary entry logic has been removed for IP protection. A generic SMA crossover is included to demonstrate the engine).
*   **Advanced Time Management:** Custom logic for Friday market close cutoffs and London Daylight Saving Time (DST) shifts to prevent weekend gap risks.
*   **Dynamic Risk Engine:** Calculates lot sizes using `OrderCalcProfit`, ensuring no single trade exceeds the user-defined maximum risk.
*   **Visual Debugging Module:** Draws custom entry lines, virtual stops, and an on-chart dashboard panel.

## 🖼️ Screenshots
![Chart Visuals](docs/images/chart.png)
![Dashboard Panel](docs/images/panel.png)

## 🛠️ Tech Stack
*   **Language:** MQL5
*   **Platform:** MetaTrader 5
*   **Concepts:** Object-Oriented Programming (OOP), State Machines, Risk Management.

## ⚠️ Disclaimer
*For educational and portfolio purposes only. The proprietary trading strategy has been stripped. Do not run on a live account. Not financial advice.*
