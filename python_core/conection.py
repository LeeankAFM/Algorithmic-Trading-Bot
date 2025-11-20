from flask import Flask, request
import os

app = Flask(__name__)

SIGNAL_PATH = r"C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\Common\Files\signal.txt"

@app.route('/webhook', methods=['POST'])
def webhook():
    data = request.json
    
    if not data:
        return "No data", 400

    signal_id = "100" 
    
    symbol = data.get('symbol')
    side = str(data.get('side')).strip().upper()
    
    risk = data.get('risk_percent')
    entry = data.get('entry')
    sl = data.get('sl')
    tp1 = data.get('tp1')
    tp2 = data.get('tp2')

    line = f"{signal_id};{symbol};{side};{risk};{entry};{sl};{tp1};{tp2}"

    print(f"Recibido: {line}")

    try:
        with open(SIGNAL_PATH, "w") as f:
            f.write(line)
        return "Signal Processed", 200
    except Exception as e:
        print(f"Error escribiendo archivo: {e}")
        print(f"Ruta intentada: {SIGNAL_PATH}")
        return "Internal Error", 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)