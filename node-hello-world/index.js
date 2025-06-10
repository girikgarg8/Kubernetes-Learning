const express = require('express');
const app = express();
const PORT = process.env.PORT;

app.get('/', (req,res) => {
    console.log('Hello World');
    res.send('Hello World');
})

app.listen(PORT, () => {
    console.log(`Server running on PORT: ${PORT}`);
})