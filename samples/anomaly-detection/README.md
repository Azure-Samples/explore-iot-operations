# Anomaly Detection Server

## Server Configuration

```yaml
logger: # Logger settings
  level: 0
server: # Server settings
  route: /anomaly
  port: 3333
algorithm: # Algorithm settings
  temperature: # Temperature related algorithm settings
    lambda: 0.25 # Lambda value for temperature anomaly detection
    lFactor: 3 # L factor for temperature anomaly detection
    controlT: 90 # Control limit T constant
    controlS: 20 # Control limit S constant
    controlN: 10 # Control limit N constant
  vibration: # Vibration related algorithm settings
    lambda: 0.25 
    lFactor: 3
    type: dynamic # Use dynamic algorithm, no requirement for control limit T, S, or N values
  humidity: # Humidity related algorithm settings
    lambda: 0.25
    lFactor: 3
    controlT: 80
    controlS: 20
    controlN: 10
```

## Algorithms

Use the `type: dynamic` property in the configuration to choose an algorithm from the following.

### Algorithm #1 - Control Limit Formula with Estimated Control Limits

$$B = L\frac{S}{\sqrt{n}}\sqrt{\frac{\lambda}{2 - \lambda}[1 - (1 - \lambda)^{2i}]}$$

$$B_u = T + B$$

$$B_l = T - B$$

<center>

| Symbol | Meaning  |
|---|---|
| $B$  | Control Limit Value  |
| $B_u$  | Upper Control Limit  |
| $B_l$  | Lower Control Limit  |
| $L$  | L Factor  |
| $\lambda$  | Lambda Factor $(0 \leq \lambda \leq 1)$ |
| $i$  | Iteration or Count |
| $T$  | Constant Estimation of Sample Mean |
| $S$  | Constant Estimation of Sample Std Dev |
| $n$  | Constant Estimation of Rational Subgroup Size |

</center>

### Algorithm #2 - Control Limit Formula with Dynamically Evaluated Control Limits (`type: dynamic`)


$$B = L\sigma_i\sqrt{\frac{\lambda}{2 - \lambda}[1 - (1 - \lambda)^{2i}]}$$ 

$$B_u = \mu_i + B$$


$$B_l = \mu_i - B$$

<center>

| Symbol | Meaning  |
|---|---|
| $B$  | Control Limit Value  |
| $B_u$  | Upper Control Limit  |
| $B_l$  | Lower Control Limit  |
| $L$  | L Factor  |
| $\lambda$  | Lambda Factor $(0 \leq \lambda \leq 1)$ |
| $i$  | Iteration or Count |
| $\mu_i$  | Sample Mean from Iteration $i$ |
| $\sigma_i$  | Sample Std Dev from Iteration $i$ |

</center>

### EWMA Value and Anomaly Detection Conditions

The following formulas are shared between the two algorithms.

__EWMA Value Formula__

$$z_{i} = \lambda x_i + (1 - \lambda)z_{i-1}$$

__Anomaly Condition__

$$
a=
\begin{cases}
0, & \text{if } B_l \leq z_i \leq B_u \\
1, & \text{otherwise}
\end{cases}
$$


<center>

| Symbol | Meaning  |
|---|---|
| $B_u$  | Upper Control Limit  |
| $B_l$  | Lower Control Limit  |
| $\lambda$  | Lambda Factor $(0 \leq \lambda \leq 1)$ |
| $i$  | Iteration or Count |
| $x_i$  | Observed Value from Iteration $i$ |
| $z_i$  | EWMA Value for Iteration $i$ |
| $a$  | Anomaly Occurance, $1$ Implies an Anomaly |

</center>