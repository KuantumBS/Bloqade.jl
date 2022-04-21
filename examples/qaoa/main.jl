# # The Maximum Independent Set Problem

# ## Background

# In graph theory, an [independent set](https://en.wikipedia.org/wiki/Independent_set_(graph_theory)) is a set of vertices in a graph, no two of which are adjacent.
# The problem of finding maximum independent sets (MIS) is NP-hard, i.e. unlikely to be solved in polynomial time for a large system size.
# In this tutorial we study the MIS problem defined on diagonal-coupled unit-disk grid graphs (DUGG).  Although these graphs have highly constraint topology, finding its MISs is still NP-hard.
# Recent studies show that these graphs can be naturally mapped to the Rydberg atom system with strong blockade interactions (see [arxiv:1808.10816](https://arxiv.org/abs/1808.10816). 
# In this tutorial, we show how to using variational quantum algorithms on Rydberg atom arrays to solve the MIS problem on these graphs.
# For those who wants to know more details, we highly recommend to connect this tutorial with the recent experiment [arxiv:2202.09372](https://arxiv.org/abs/2202.09372).

# Let's start by importing the required libraries:

using Graphs
using Bloqade
using Compose
using Random
using GenericTensorNetworks
using Optim
using PythonCall
plt = pyimport("matplotlib.pyplot")

# # Set up the problem

# To begin with, we create a ``4*4`` DUGG with 0.8 filling, by using the [`random_dropout`](@ref) function. Here we choose the lattice constant ``a`` to be 4.5 ``\mu m``. 
Random.seed!(2)
atoms = generate_sites(SquareLattice(), 4, 4; scale=4.5) |> random_dropout(0.2)

# Then we set the blockade radius to be 7.5 ``\mu m``. In such a case,  if two atoms have a distance of ``a`` or ``\sqrt{2} a``, they are within the blockade radius. 
# As we discussed in [Rydberg Blockade](@ref), there is only one Rydberg excitation is allowed within the blockade radius.  To better illustrate the constraint, we 
# plot the interactions of Rydberg atoms as a DUGG, where each edge corresponds to the blockade constraint given by the strong Rydberg interactions. 
Bloqade.plot(atoms, blockade_radius=7.5)
# Our goal is to find a the maximum independent sets of such a graph. 


# For the pedagogical purpose, we first calculate the MIS size here using the graph utilities in Bloqade so that a user can compare this exact result with the quantum one.
# The exact MIS size and its degeneracy can be solved with the generic tensor network algorithm in package [`GenericTensorNetworks`](https://github.com/QuEraComputing/GenericTensorNetworks.jl).
graph = BloqadeMIS.unit_disk_graph(atoms, 7.5)
mis_size_and_counting = GenericTensorNetworks.solve(IndependentSet(graph), CountingMax())[]

# The `solve` function takes a graph instance and a solution space property as inputs,
# where the graph instance is generated by the [`unit_disk_graph`](@ref) function in module `BloqadeMIS`.
# For this specific DUGG, we see that the MIS size is 4, and the function also outputs number of independent sets of such size.
# In the following, we are going to solve the independent set problem with both adiabatic and variational algorithms.



# ## The adiabatic approach

# Here we generalize the adiabatic algorithm we used in [Adiabatic Evolution](@ref) to prepare ground states for this disordered lattice. 
# We first construct the adiabatic pulse sequences for Rabi frequency ``\Omega`` and detuning ``\Delta``.

T_max = 1.65
Ω_max = 2π *4
Ω = piecewise_linear(clocks=[0.0, 0.2, 1.45, T_max], values=[0.0, Ω_max , Ω_max , 0])
Δ_start = -2π *13 
Δ_end =  2π *11
Δ = piecewise_linear(clocks=[0.0, 0.2, 1.45, T_max], values=[Δ_start, Δ_start, Δ_end, Δ_end])

fig, (ax1, ax2) = plt.subplots(ncols = 2, figsize = (12, 4))
Bloqade.plot!(ax1, Ω/2π)
ax1.set_ylabel("Ω/2π (MHz)")
Bloqade.plot!(ax2, Δ/2π)
ax2.set_ylabel("Δ/2π (MHz)")
fig


# Here, the total time is fixed to `T_max`, the adiabatic evolution path is specified by the [`piecewise_linear`](@ref) function.
# Rydberg blockade radius can be computed with 
# ```math
# C_6 / R_b^6 \sim \sqrt{\Delta^2 + \Omega^2}
# ```
# For the default ``C_6=2π * 862690 * MHz*µm^6`` and ``\Omega = 0``, if we want to set the the blockade radius to be ``7.5\mu m``, the corresponding 
# detuning is ``2\pi \times \sim 11  MHz`` (see the parameter in [arxiv:2202.09372](https://arxiv.org/abs/2202.09372)). This is the reason why we have chosen 
# ``Δ_end =  2π *11 MHz``. 


# Then we create the time-dependent Hamiltonian and emulate its time evolution by using the [`SchrodingerProblem`](@ref) solver.

hamiltonian = rydberg_h(atoms; Ω=Ω, Δ=Δ)
prob = SchrodingerProblem(zero_state(nqubits(hamiltonian)), T_max, hamiltonian)
emulate!(prob)

# Finally, we can plot the most probable bitstrings by using [`bitstring_hist`]@(ref) for the resulting register (quantum state)
bitstring_hist(prob.reg; nlargest=20)

# One can see the most probable several configurations indeed have size 4 by counting the number of ones.
# This correctness of the output can be verified by comparing it to the classical solution.

best_bit_strings = most_probable(prob.reg, 2)
all_optimal_configs = GenericTensorNetworks.solve(IndependentSet(graph), ConfigsMax())[]
@assert all(bs->GenericTensorNetworks.StaticBitVector([bs...]) ∈ all_optimal_configs.c, best_bit_strings)

# We can also visualize these atoms and check them visually.
Bloqade.plot(atoms; colors=[iszero(b) ? "white" : "black" for b in best_bit_strings[1]])
#
Bloqade.plot(atoms; colors=[iszero(b) ? "white" : "black" for b in best_bit_strings[2]])




# ## QAOA with piecewise constant pulses
# The QAOA algorithm ([arxiv:1411.4028](https://arxiv.org/abs/1411.4028)) is a hybrid quantum-classical algorithm. The classical part of the algorithm is an optimizer, which can be either a gradient based or non-gradient based one.
# For our specific problem, the corresponding quantum part is a Rydberg atom system evolving under parameterized pulse sequences and finally got measured on the computational basis.


# The standard definition of QAOA involves applying the problem (cost function) Hamiltonian ``C`` and the transverse field Hamiltonian ``B`` alternately.
# Let ``G=(V,E)`` be a graph, the hamiltonian for an MIS problem definite on it should be
# ```math
# C(G, \sigma^z) = -\sum_{i\in V} w_i \sigma_i^z + \infty \sum_{\langle i,j\rangle \in E}\sigma_i^z \sigma_j^z
# ```
#where the first summation is proportional to the size of the independent set, while the second term enfores the independence constraints.


# In a Rydberg hamiltonian, the first term corresponds to the detuning ``\Delta``.
# The second term contains an ``\infty``, which corresponds to the Rydberg blockade term that its strength decreases very fast as distance: ``\propto |r_i - r_j|^{-6}``.
# It is not a perfect independent constraint term, hence proprocessing might be required in a Rydberg atom array experiment.
#
# The transverse field Hamiltonian corresponds to the Rabi term in a Rydberg atom array.
# ```math
# B = \sum_{j=1}^{n}\sigma_j^x
# ```

# For the convenience of simulation, we use the [`expect`](@ref) function to get the averaged measurement output. 
# In an experimental setup, the [`expect`] should be replaced by measuring on the computational basis and get the averaged number of Rydberg excitations as the loss function.
# Then one can either use non-gradient based optimizers to do the optimization or use finite difference obtain gradients of parameters.

#  Let us first set up a non-optimized pulse sequences for QAOA with step ``p=3``. 

durations = [0.1, 0.5, 0.3, 0.3, 0.2, 0.4]
clocks = [0, cumsum(durations)...]
Ω2 = piecewise_constant(; clocks=clocks, values=repeat([Ω_max, 0.0], 3))
Δ2 = piecewise_constant(; clocks=clocks, values=repeat([0.0, Δ_end], 3))

fig, (ax1, ax2) = plt.subplots(ncols = 2, figsize = (12, 4))
Bloqade.plot!(ax1, Ω2/2π)
ax1.set_ylabel("Ω/2π (MHz)")
Bloqade.plot!(ax2, Δ2/2π)
ax2.set_ylabel("Δ/2π (MHz)")
fig


# `piecewise_constant` pulses can be more accurately solved with the [`KrylovEvolution`](@ref) solver.
hamiltonian2 = rydberg_h(atoms; Ω=Ω2, Δ=Δ2)
nbits = length(atoms)
prob2 = KrylovEvolution(zero_state(nbits), clocks, hamiltonian)
emulate!(prob2);

# We defined a loss function as the mean MIS size, which corresponds to the expectation value of [`SumOfN`](@ref) operator. Then we can calculate the 
# average loss function after the time evolution  
loss_MIS(reg) = -real(expect(SumOfN(nsites=nbits), reg))
loss_MIS(prob2.reg)

# The ouput shows the negative mean independent set size. This is because  we have flipped its sign since most optimizers are set to minimize the the loss function.


# Here, the loss does not look good, we can throw it into an optimizer and see if a classical optimizer can help. 
# But first, let us wrap up the above code into a loss function.

function loss_piecewise_constant(atoms::AtomList, x::AbstractVector{T}) where T
    @assert length(x) % 2 == 0
    Ω_max = 4 * 2π
    Δ_end = 11 * 2π
    p = length(x)÷2
    ## detuning and rabi terms
    durations = abs.(x)   # the durations of each layer of QAOA pulse take the optimizing vector x as their input 
    clocks = [0, cumsum(durations)...]
    Ωs = piecewise_constant(; clocks=clocks, values=repeat(T[Ω_max, 0.0], p))
    Δs = piecewise_constant(; clocks=clocks, values=repeat(T[0.0, Δ_end], p))

    hamiltonian = rydberg_h(atoms; Ω=Ωs, Δ=Δs)
    subspace = blockade_subspace(atoms, 7.5)  # we run our emulation within the blockade subspace 
    prob = KrylovEvolution(zero_state(Complex{T}, subspace), clocks, hamiltonian)
    emulate!(prob)

    ## results are bit strings
    nbits = length(atoms)
    ## return real(sum(prob.reg.state))
    return -real(expect(sum([put(nbits, i=>ConstGate.P1) for i=1:nbits]), prob.reg)), prob.reg
end

# !!!note
#     Running the emulation in subspace does not violate the independence constraints.
#     In practice, one needs to post-process the measured bit strings to a get a correct measure of loss.


# Let us check the loss function by using a random input 

x0 = (Random.seed!(2); rand(6))
mean_mis, reg0 = loss_piecewise_constant(atoms, x0)
mean_mis

# The most probable bitstrings are

bitstring_hist(reg0; nlargest=20)

# We see that, without optimization, many of these bitstrings are not the MIS solutions. 

# Let us now use the non-gradient based optimizer `NelderMead` in the `Optim` package to optimize the loss
optresult = Optim.optimize(x->loss_piecewise_constant(atoms, x)[1], x0)

mean_mis_final, reg_final = loss_piecewise_constant(atoms, optresult.minimizer)
mean_mis_final

# We see that the loss is indeed decreased, but not much. This is probably because the program is trapped in a local minimal.

bitstring_hist(reg_final; nlargest=20)

# The good thing is that the most probable bitstring now converge to the solutions of MIS. 

# To better solve the local minimal issue, below we try  a set of different optimizations by parameterizing the curve using smoothen piecewise linear waveforms. 

# ## Smoothen Piecewise linear pulses

# A smoothen piecewise linear waveform can be created by applying a Gaussian filter on a waveform created by the [`piecewise_linear`] function.
smoothen_curve = smooth(piecewise_linear(clocks=[0.0, 0.2, 1.45, T_max], values=[0.0, Ω_max , Ω_max , 0]); kernel_radius=0.1); 
Bloqade.plot(smoothen_curve)

# Here, the function [`smooth`](@ref) takes a `kernel_radius` keyword parameter as the Gaussian kernel parameter.
# With the new waveform, we can define the loss as follows.

function loss_piecewise_linear(atoms::AtomList, x::AbstractVector{T}) where T
    @assert length(x) == 3
    Ω_max = 4 * 2π
    Δ_start = -13 * 2π
    Δ_end = 11 * 2π
    Δ0 = 11 * 2π
    T_max = 0.6
    ## the strength of the detunings in each step takes the optimizing x as their input 
    Δs = smooth(piecewise_linear(clocks=T[0.0, 0.1, 0.2, 0.3, 0.4, 0.5, T_max], values=T[Δ_start, Δ_start, Δ0*x[1], Δ0*x[2], Δ0*x[3], Δ_end, Δ_end]); kernel_radius=0.1)
    Ωs = smooth(piecewise_linear(clocks=T[0.0, 0.1, 0.5, T_max], values=T[0.0, Ω_max , Ω_max , 0]); kernel_radius=0.05)

    hamiltonian = rydberg_h(atoms; Ω=Ωs, Δ=Δs)
    subspace = blockade_subspace(atoms, 7.5)
    prob = SchrodingerProblem(zero_state(Complex{T}, subspace), T_max, hamiltonian)
    emulate!(prob)

    ## results are bit strings
    nbits = length(atoms)
    ## return real(sum(prob.reg.state))
    return -real(expect(sum([put(nbits, i=>ConstGate.P1) for i=1:nbits]), prob.reg)), prob.reg, Δs
end

x0 = [0.1, 0.8, 0.8]

# Let us check the loss function
mean_mis, reg0, Δ_initial = loss_piecewise_linear(atoms, x0)
Bloqade.plot(Δ_initial)
mean_mis

# If we plot the distribution
bitstring_hist(reg0; nlargest=20)

# It is quite good already. Again, let us use the `NelderMead` optimizer to optimize the loss
optresult = Optim.optimize(x->loss_piecewise_linear(atoms, x)[1], x0)

mean_mis_final, reg_final, Δ_final = loss_piecewise_linear(atoms, optresult.minimizer)
mean_mis_final
# One can see the mean MIS size can be further improved to a value close to optimal value of MIS solution.

bitstring_hist(reg_final; nlargest=20)

# We can also plot out the final optimized waveform for Δ
Bloqade.plot(Δ_final)
